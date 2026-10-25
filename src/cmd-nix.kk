/* Commands that drive Nix, plus the ones that report on a project. */

module src/cmd-nix

import std/os/dir
import std/os/file
import std/os/path
import std/os/process

import util

import src/args
import src/cmd
import src/project
import src/strutil
import src/templates
import src/term

// ---------- nix passthroughs ----------

// These four are thin on purpose: koki is a front end for Nix, not a
// replacement for it. Each resolves the project first, so running one in the
// wrong directory gets a sentence about that instead of a Nix error.

pub fun cmd-build(p : parsed) : io int
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  out-step("nix build")
  nix-in(root, "build")

pub val build-args : list<argdef> = []

pub fun cmd-run(p : parsed) : io int
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  // `nix run` needs an explicit installable before the `--`, or it reads the
  // first pass-through word as one.
  val extra = p.positional ++ p.passthru
  val tail  = if extra.is-empty then "" else " . -- " ++ str-shjoin(extra)
  out-step("nix run" ++ tail)
  nix-in(root, "run" ++ tail)

pub val run-args : list<argdef> = []

pub fun cmd-check(p : parsed) : io int
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  out-step("nix flake check")
  val rc = nix-in(root, "flake check")
  if rc == 0 then out-ok("all checks passed")
  rc

pub val check-args : list<argdef> = []

pub fun cmd-dev(p : parsed) : io int
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  // `nix develop` takes its command as `--command`, not after a bare `--`.
  val cmdline = p.positional ++ p.passthru
  val tail    = if cmdline.is-empty then "" else " --command " ++ str-shjoin(cmdline)
  out-step("nix develop" ++ tail)
  nix-in(root, "develop" ++ tail)

pub val dev-args : list<argdef> = []

// ---------- the REPL ----------

// `koka -p` opens the interactive compiler, but on its own it only sees the
// project directory. A dependency is a set of modules under a Nix store path,
// and the compiler only reads those when the directory is on its module path,
// so the REPL needs the same `--include` flags the build phase uses or
// `import` of anything `koki add` brought in fails. Those flags are read out
// of the `koka.json` the dev shell's hook writes, so the REPL and the build
// cannot drift apart about what a dependency is.

val dquote : string = "\""

// The contents of the first `[...]` in `s`, one entry per comma-separated
// field with the quotes taken off. A list that is never closed yields what is
// there rather than nothing.
fun bracket-list(s : string) : div list<string>
  val open : int = s.list.index-of(_ == '[')
  if open < 0 then []
  else
    val rest : list<char> = s.list.drop(open + 1)
    val close : int = rest.index-of(_ == ']')
    val inner = if close < 0 then rest else rest.take(close)
    str-split-char(inner.string, ',').map(unquote-field)

// One `"..."` field. A field that is not quoted is kept as it stands, so a
// hand-edited file still yields something the compiler can be pointed at.
fun unquote-field(s : string) : div string
  val t = s.trim
  val cs = t.list
  if cs.length >= 2 && str-starts-with(t, dquote) && str-ends-with(t, dquote) then
    cs.drop(1).take(cs.length - 2).string.trim
  else t

// The include directories recorded in a `koka.json`. A file without the key
// yields none rather than an error: the REPL is still worth opening, and a
// module that cannot be found says more about the problem than this would.
// An entry that is empty is dropped, because `koka` reads an empty
// `--include` as "reset the module path", which would lose every directory
// that came before it.
pub fun include-dirs(text : string) : div list<string>
  match str-after(text, "\"include_dirs\"")
    Nothing    -> []
    Just(rest) -> bracket-list(rest).filter(_.is-notempty)

// The compiler flags those directories turn into.
pub fun include-args(text : string) : div list<string>
  include-dirs(text).map("--include=" ++_)

// Enter the dev shell just to let its hook write `koka.json`, then read it
// back. Only ever done when the file is missing, which is the first time a
// project is opened and every time after is a plain read.
fun prime-koka-json(root : path) : io list<string>
  out-step("reading the project's include path")
  nix-in(root, "develop --command true")
  match read-if-there(root/"koka.json")
    Nothing -> []
    Just(t) -> include-args(t)

pub fun cmd-repl(p : parsed) : io int
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  val includes = match read-if-there(root/"koka.json")
    Nothing -> prime-koka-json(root)
    Just(t) -> include-args(t)
  // Whatever the user adds goes after the includes, so `koki repl --` reaches
  // `koka` untouched; the REPL reads the same stdin the user is typing on.
  val extra = p.positional ++ p.passthru
  val tail = if extra.is-empty then "" else " " ++ str-shjoin(extra)
  out-step("koka -p" ++ (if includes.is-empty then "" else " " ++ str-shjoin(includes)) ++ tail)
  nix-in(root, "develop --command koka -p " ++ str-shjoin(includes) ++ tail)

pub val repl-args : list<argdef> = []

// ---------- reading facts out of Nix ----------

// The version the flake would actually build. Nix is asked directly rather
// than the text being parsed, so this stays right when the version is only
// defaulted somewhere in the expression.
fun built-version(root : path) : io maybe<string>
  val cmd = "cd " ++ root.string ++
            " && s=$(nix eval --impure --raw --expr builtins.currentSystem)" ++
            " && nix eval --raw .#packages.$s.default.version 2>/dev/null"
  match run-system-read(cmd)
    Ok(s)    -> if s.trim.is-empty then Nothing else Just(s.trim)
    Error(_) -> Nothing

// ---------- info ----------

fun row(label : string, value : string) : io ()
  println("  " ++ label.pad-right(13).dim ++ value)

fun nixpkgs-pin(f : kflake) : maybe<string>
  nixpkgs-ref(flake-input-refs(f))

fun nixpkgs-ref(refs : list<inputref>) : maybe<string>
  match refs.find(_.name == "nixpkgs")
    Just(r) -> Just(r.source)
    Nothing -> Nothing

// The two lines `koki info` spends on each dependency: where it came from, and
// the expression that puts it on the module path.
fun show-dep(d : kdep) : io ()
  println("  " ++ d.input-name.pad-right(16).bold ++ d.source)
  println("  " ++ dim(" ".repeat(16) ++ d.entry))

pub fun cmd-info(p : parsed) : io int
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  val f = match require-flake(root)
    Nothing -> return 1
    Just(x) -> x
  val deps = f.flake-deps
  "koka project".bold.out-heading
  out-blank()
  row("name",     flake-name(f))
  row("path",     root.string)
  row("version",  built-version(root).default("(not evaluated)"))
  row("nixpkgs",  nixpkgs-pin(f).default("(not pinned)"))
  row("lockfile", if (root/"flake.lock").is-file then "present" else "missing".yellow)
  row("deps",     deps.length.show)
  out-blank()
  "dependencies".bold.out-heading
  out-blank()
  if deps.is-empty then
    "none yet — `koki add nel-kk` adds one".dim.out-item
  else
    deps.foreach(show-dep)
  out-blank()
  0

pub val info-args : list<argdef> = []

// ---------- doctor ----------

// A check result. `level` is 0 for fine, 1 for advice, 2 for a problem that
// makes koki useless until it is fixed.
pub struct check
  label : string
  level : int
  help  : string

fun fine(label : string) : check
  Check(label, 0, "")

fun advice(label : string, help : string) : check
  Check(label, 1, help)

fun broken(label : string, help : string) : check
  Check(label, 2, help)

fun render-checks(cs : list<check>) : io ()
  cs.foreach fn(c)
    val mark = match c.level
      0 -> "✔".green
      1 -> "!".yellow
      _ -> "✖".red
    println(mark ++ " " ++ c.label)
    if !c.help.is-empty then out-hint(c.help)

fun count-broken(cs : list<check>) : int
  match cs
    Nil          -> 0
    Cons(hd, tl) -> (if hd.level >= 2 then 1 else 0) + count-broken(tl)

fun count-advice(cs : list<check>) : int
  match cs
    Nil -> 0
    Cons(hd, tl) -> (if hd.level == 1 then 1 else 0) + count-advice(tl)

fun toolchain-checks() : io list<check>
  val nix-check =
    if have-exe("nix") then
      [ fine("nix " ++ first-line-of("nix --version")) ]
    else
      [ broken("nix is not on the PATH", "install Nix: https://nixos.org/download.html") ]
  val git-check =
    if have-exe("git") then
      [ fine("git " ++ first-line-of("git --version")) ]
    else
      [ advice("git is not on the PATH", "`koki init` cannot make a repository without it") ]
  val koka-check =
    if have-exe("koka") then
      [ fine("koka " ++ first-line-of("koka --version")) ]
    else
      [ advice("koka is not on the PATH", "run `koki dev` for a shell that has it") ]

  nix-check ++ git-check ++ koka-check

// Checks that only make sense inside a project directory.
fun project-checks(root : path) : io list<check>
  val ftext = read-if-there(root/"flake.nix")
  val file-checks = match ftext
    Nothing -> [ broken("cannot read "%^[root/"flake.nix"], "check the permissions") ]
    Just(t) -> match parse-flake(t)
      Nothing -> [ broken("flake.nix has no koki marker regions",
                          "koki edits two marked regions and cannot find them") ]
      Just(f) -> flake-checks(f)
  val lock-check =
    if is-file(root/"flake.lock") then [ fine("flake.lock is present") ]
    else [ advice("no flake.lock yet", "run `koki build` or `nix flake lock`") ]
  val ignore-check = match read-if-there(root / ".gitignore")
    Nothing -> [ advice("no .gitignore; build output would be committed",
                        "add at least .koka/, koka.json and result") ]
    Just(t) ->
      if   gitignore-covers(t, ".koka")
      &&   gitignore-covers(t, "koka.json")
      &&   gitignore-covers(t, "result")
      then [ fine(".gitignore covers .koka/, koka.json and result") ]
      else [ advice(".gitignore is missing some generated files",
                 "add .koka/, koka.json and result") ]
  file-checks ++ lock-check ++ ignore-check

// One line per dependency in the doctor report, as named functions rather than
// lambdas so the field accesses stay readable next to the check they build.
fun dep-name(d : kdep) : string
  d.input-name

fun describe-dep(d : kdep) : io check
  fine(dim(d.input-name ++ "  " ++ d.source))

fun orphan-dep(d : kdep) : bool
  d.source == "(not in inputs)"

// The checks that read the flake itself: markers, dependencies, and whether
// every dependency still has the input it refers to.
fun flake-checks(f : kflake) : io list<check>
  val deps    = f.flake-deps
  val marker  = [ fine("flake.nix has the koki marker regions") ]
  val summary = fine(deps.length.show ++ " dependenc"
                     ++ (if deps.length == 1 then "y" else "ies"))
  val listed    = deps.map(describe-dep)
  val dep-check = if deps.is-empty then [ fine("no dependencies") ]
                  else [ summary ] ++ listed
  // A dependency without a matching input cannot evaluate. Catching it here
  // beats letting the next `nix build` fail with a much longer sentence.
  val orphans      = deps.filter(orphan-dep)
  val orphan-check =
    if orphans.is-empty then []
    else [ broken("dependencies with no flake input: " ++ orphans.map(dep-name).join(", "),
                  "add the matching entry to the inputs region of flake.nix") ]
  marker ++ dep-check ++ orphan-check

pub fun cmd-doctor(p : parsed) : io int
  "koki doctor".bold.out-heading
  out-blank()
  "toolchain".dim.out-heading
  val tool = toolchain-checks()
  render-checks(tool)
  out-blank()
  "project".dim.out-heading
  val root = project-root()
  val proj = match root
    Nothing ->
      [ advice("not inside a koki project", "run `koki init` to create one") ].render-checks
      []
    Just(r) ->
      [ fine("project root: " ++ r.string) ].render-checks
      project-checks(r)

  out-blank()
  val all  = tool ++ proj
  val bad  = count-broken(all)
  val warn = count-advice(all)
  if   bad == 0 && warn == 0 then out-ok("everything checks out")
  elif bad == 0 then out-warn(warn.show ++ " thing" ++ (if warn == 1 then "" else "s") ++ " to look at")
  else out-error(bad.show ++ " problem" ++ (if bad == 1 then "" else "s") ++ " to fix")
  out-blank()
  if bad == 0 then 0 else 1

pub val doctor-args : list<argdef> = []
