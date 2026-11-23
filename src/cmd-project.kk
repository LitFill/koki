/* Commands that create a project or change its dependencies. */

module src/cmd-project

import std/os/dir
import std/os/file
import std/os/path
import std/os/process

import util

import src/args
import src/cmd
import src/project
import src/registry
import src/strutil
import src/templates
import src/term

// ---------- shared plumbing ----------

fun safe-dir(p : path) : io bool
  match try({ p.is-directory })
    Ok(b)    -> b
    Error(_) -> False

fun non-empty-dir(p : path) : io bool
  match try({ list-directory(p).length > 0 })
    Ok(b)    -> b
    Error(_) -> False

fun this-year() : io string
  match run-system-read("date +%Y")
    Ok(s)    -> last(s.str-lines).default("")
    Error(_) -> "2026"

// ---------- koka detection ----------

// A Koka project, before koki touches it. Any one of these says the directory
// already holds Koka code that `koki init` must not clobber blindly:
//   - a .kk source file anywhere inside (covers src/, test/, root, etc.)
//   - a koka.json (the dev shell's include path)
//   - a flake.nix that mentions koka (koka build input, koka in a package name)
fun is-koka-project(p : path) : io bool
  if is-file(p / "koka.json") then return True
  if has-koka-flake(p / "flake.nix") then return True
  has-kk-file(p)

// Does this flake.nix mention Koka? A non-existent file is simply not a koka
// flake; an unreadable one is not either — the caller handles the read error.
fun has-koka-flake(p : path) : io bool
  match try fn() { p.read-text-file }
    Ok(s)    -> s.contains("koka")
    Error(_) -> False

// Does the directory tree contain at least one .kk source file?
fun has-kk-file(p : path) : io bool
  match try fn() { list-directory(p) }
    Error(_) -> False
    Ok(entries) ->
      entries.any fn(e) { entry-is-kk(e) }

// A single directory entry is a .kk file, or a directory that contains one.
fun entry-is-kk(e : path) : io bool
  if e.is-file && e.string.str-ends-with(".kk") then return True
  if !e.is-directory then return False
  has-kk-file(e)

// Which files to skip when `--merge` is active and the target is a koka
// project. Skipping means "leave the user's copy alone"; every other template
// file (flake.nix, .gitignore, README.md, …) is still written.
fun skip-patterns() : list<string>
  [ "main.kk", "example.kk", "test/test.kk" ]

// The module path koki's lib template would generate.
fun lib-module-path(name : string) : string
  "src/" ++ str-snake(name) ++ ".kk"

// Should this file be preserved during a merge? Returns True to skip (keep the
// user's existing copy). A template path is either in the fixed skip list or
// matches the library module for this project's name.
fun should-skip-merge(f : newfile, name : string) : bool
  if skip-patterns().contains(f.path) then return True
  f.path == lib-module-path(name)

// Report the template files a merge leaves alone. Each one is a file the user
// already owns (see should-skip-merge), so it is kept rather than overwritten.
fun out-kept(files : list<newfile>) : io ()
  match files
    Nil -> ()
    Cons(f, tl) ->
      out-item("keep    " ++ f.path ++ " (existing)")
      out-kept(tl)

// The `koki init` decision after the arguments are parsed: whether the target
// is an existing koka project and how to handle the template files.
//
//   KokaEmpty        — nothing there; write everything
//   KokaMerge        — a koka project with no flake.nix; write only support files
//   KokaOverwrite    — a koka project with a flake.nix; merge/skip source files
pub type koka-state
  KokaEmpty
  KokaMerge
  KokaOverwrite

// Classify the target directory.
fun classify-koka(root : path) : io koka-state
  if !is-koka-project(root) then return KokaEmpty
  if is-file(root / "flake.nix") then KokaOverwrite else KokaMerge

// Is this state the "no koka project" case? Named to avoid needing (==) on
// the koka-state type, which Koka does not derive.
fun is-empty-koka(s : koka-state) : bool
  match s
    KokaEmpty -> True
    _         -> False

// ---------- init ----------

pub val init-args : list<argdef> = [
  arg-opt("name",        "n", "NAME", "project name (default: the directory name)"),
  arg-opt("template",    "t", "KIND", "bin, lib or test (default: bin)"),
  arg-opt("description", "d", "TEXT", "one-line description"),
  arg-opt("author",      "a", "NAME", "copyright holder"),
  arg-opt("license",     "l", "TEXT", "license name (default: MIT)"),
  arg-opt("pkg-version", "",  "VER",  "starting version (default: 0.1.0)"),

  arg-switch("yes",     "y", "take every default without asking"),
  arg-switch("force",   "f", "overwrite files that already exist"),
  arg-switch("merge",   "",  "keep existing source files when initialising in a koka project"),
  arg-switch("git",     "",  "run `git init` (default: yes; --no-git to skip)"),
  arg-switch("dry-run", "",  "print what would be created, write nothing"),
]

val template-kinds : list<string> = [ "bin", "lib", "test" ]

// The name a project gets when nothing else says otherwise: the directory it
// is created in, or the working directory when the project is the current one.
fun default-name(dir : string) : string
  str-sanitize-name(if dir.is-empty then "koka-app" else dir)

// Everything `koki init` needs to know. Koka has no six-tuples, and a record
// reads better at the call site anyway.
pub struct answers
  name    : string
  kind    : string
  desc    : string
  author  : string
  license : string
  version : string

// Ask for whatever was not passed on the command line. Without a terminal
// there is nobody to ask, so the defaults stand.
fun ask-missing(p : parsed, dir : string) : io answers
  val tmpl   = template-kinds.join(", ")
  val ask    = !p.has("yes") && term-interactive()
  val base   = if dir.is-empty || dir == "." then basename(cwd()) else dir
  val name   = p.value("name").default(if ask then prompt-ask("Project name", default-name(base)) else default-name(base))
  val kind   = p.value("template")   .default(if ask then prompt-ask("Template (%1)"%^[tmpl], "bin")    else "bin")
  val desc   = p.value("description").default(if ask then prompt-ask("Description", "A Koka project")   else "A Koka project")
  val author = p.value("author")     .default(if ask then prompt-ask("Author", "Anonymous")             else "Anonymous")
  val lic    = p.value("license")    .default(if ask then prompt-ask("License", "MIT")                  else "MIT")
  val ver    = p.value("pkg-version").default(if ask then prompt-ask("Version", "0.1.0")                else "0.1.0")
  Answers(name, kind, desc, author, lic, ver)

fun check-kind(kind : string) : io bool
  if template-kinds.contains(kind) then return True
  out-error("unknown template '%1'"%^[kind])
  out-hint("choose one of: " ++ template-kinds.join(", "))
  return False

// Write one template file, reporting what happened.
fun emit(root : path, f : newfile, dry : bool) : io bool
  if dry then
    out-item("create  " ++ f.path)
    return True
  if !write-file(root / f.path, f.body) then return False
  out-item("create  " ++ f.path)
  True

fun emit-all(root : path, files : list<newfile>, dry : bool) : io bool
  match files
    Nil -> return True
    Cons(f, tl) ->
      if !emit(root, f, dry) then return False
      emit-all(root, tl, dry)

// Stage exactly the files koki wrote, so that Nix can see them without
// pulling in whatever else the directory holds. `-f` because a directory koki
// was told to write into (`--force`) may carry a `.gitignore` that would hide
// one of them, and an untracked file is invisible to `nix build`.
fun stage(root : path, files : list<newfile>) : io bool
  val paths = files.map(_.path.str-shquote).join(" ")
  run-system("git -C %1 add -f -- %2"%^[str-shquote(root.string), paths]) == 0

// Make the project visible to Nix through git and report what happened:
// `Nothing` when koki left git alone (`--no-git`, or git could not run),
// `Just(b)` when a repository exists and `b` says whether the project files
// are staged. Nix reads a flake through git, so untracked files make
// `koki build` fail with a message about tracking rather than about the build.
// Only the files koki wrote are staged: `add -A` in a directory that already
// had a repository would stage whatever else the user keeps there.
fun init-git(root : path, files : list<newfile>, enabled : bool) : io maybe<bool>
  if !enabled then return Nothing
  val quoted = str-shquote(root.string)
  // A repository above `root` does not count: koki only ever creates one here,
  // and `git init` in a directory that already has one is a no-op.
  val dot-git = root / ".git"
  val had-repo = is-directory(dot-git) || is-file(dot-git)
  val init-rc = if had-repo then 0 else run-system("git init -q " ++ quoted)
  if init-rc != 0 then
    out-warn("could not run `git init`; the rest of the project is complete")
    return Nothing
  val staged = stage(root, files)
  if staged then
    out-ok(if had-repo then "staged the project files"
                      else "initialised a git repository and staged the files")
  else
    out-warn("could not stage the files; `nix build` will not see them until they are added to git")
  Just(staged)

pub fun cmd-init(p : parsed) : io int
  val dir  = last(p.positional).default(".")
  val root = dir.path
  val a    = ask-missing(p, dir)
  val name = a.name
  val kind = a.kind
  if !check-kind(kind) then return 2
  if !str-valid-name(name) then
    out-error("'" ++ name ++ "' is not a usable project name")
    out-hint("use lowercase letters, digits and single dashes, like `my-app`")
    return 2

  val dry = p.has("dry-run")
  val state = classify-koka(root)
  val merge = p.has("merge") && !is-empty-koka(state)
  // Writing into a directory that already holds files needs `--force`. A koka
  // project is the case worth naming: its source files would be clobbered, and
  // `--merge` is what preserves them.
  val occupied = safe-dir(root) && non-empty-dir(root)
  if !dry && occupied && !p.has("force") && !merge then
    if is-empty-koka(state) then
      out-error(root.string ++ " is not empty")
      out-hint("pass --force to write into it anyway, or name another directory")
    else
      out-error(root.string ++ " already holds a koka project")
      out-hint("pass --merge to keep its source files, or --force to overwrite them")
    return 1

  if merge then
    match state
      KokaMerge ->
        out-step(root.string ++ " looks like a koka project; adding koki files")
      KokaOverwrite ->
        out-step(root.string ++ " looks like a koki-managed koka project; refreshing")
      KokaEmpty -> ()

  if !dry then
    match try({ root.ensure-dir })
      Ok(_)    -> ()
      Error(e) ->
        out-error("cannot create %1: %2"%^[root.string, e.message])
        return 1

  val s = Settings(name, a.desc, a.version, a.author, a.license, this-year(), kind)
  val files = template-files(s)
  // With `--merge` in a koka project the template's source files would clobber
  // the user's own, so keep those and write everything else (flake.nix,
  // .gitignore, …). Without merge — an empty directory — every file is written.
  val kept = if merge then files.filter(fn(f) should-skip-merge(f, name)) else []
  val files-to-write = if merge then files.filter(fn(f) !should-skip-merge(f, name)) else files
  if merge then
    out-step("merging into " ++ root.string ++ " (source files preserved)")
  else
    out-step("creating a %1 project in %2"%^[kind, root.string])
  out-kept(kept)
  if !emit-all(root, files-to-write, dry) then return 1
  if dry then
    out-ok("dry run: nothing was written")
    return 0

  // Stage exactly the files koki wrote, so that Nix can see them without
  // pulling in whatever else the directory holds.
  val git = init-git(root, files-to-write, flag-on(p, "git", True))
  out-ok("created %1 (%2)"%^[bold(name), kind])
  // The commit step only makes sense when a repository exists and its files
  // are staged; a failed `git init` must not leave a `git commit` hint behind.
  val commit =
    match git
      Just(True) -> [ ("commit it", "git commit -m 'initial commit'") ]
      _          -> []
  val steps =
    if dir == "." then
      [ ("enter the dev shell", "koki dev"),
        ("build and run it", "koki run") ] ++ commit
    else
      [ ("enter the project", "cd " ++ dir),
        ("enter the dev shell", "koki dev"),
        ("build and run it", "koki run") ] ++ commit
  next-steps(steps)
  0

// ---------- new ----------

pub val new-args : list<argdef> = init-args.drop(1)

pub fun cmd-new(p : parsed) : io int
  if p.positional.is-empty then
    out-error("`koki new` needs a name")
    out-hint("for example: koki new my-app")
    return 2

  val name = last(p.positional).default("")
  val dir = p.positional.@index(1).default(name)
  cmd-init(set-opt(set-positional(p, [ dir ]), "name", Just(name)))

// ---------- add ----------

pub val add-args : list<argdef> = [
  arg-opt("attr",    "", "NAME", "flake output attribute holding the library"),
  arg-opt("library", "", "NAME", "name under `kokaLibraries` in that flake"),
  arg-switch("dry-run", "",  "print the change, write nothing"),
  arg-switch("yes",     "y", "do not ask for confirmation"),
]

// One dependency resolved to the four things the flake needs to record it.
pub struct addition
  input  : string
  source : string
  attr   : string
  style  : string
  entry  : string

// One dependency edit: the flake attribute, what to call it in messages (the
// user's spelling), and the two fields only an addition uses.
pub struct edit
  name  : string
  input : string
  ref   : string
  entry : string

// Which way an edit goes.
pub type edit-direction
  Adding
  Removing

// Apply edits one at a time, so each sees the file the previous one produced.
// The third result is the edits that did not apply, in the order they were
// given: an addition that is already there, or a removal that is not.
pub fun apply-edits(
  text    : string,
  edits   : list<edit>,
  dir     : edit-direction,
  done    : list<string>,
  skipped : list<string>
) : io (string, list<string>, list<string>)
  match edits
    Nil -> (text, done, skipped)
    Cons(e, tl) ->
      val f = match parse-flake(text)
        Just(x) -> x
        Nothing ->
          out-error("flake.nix stopped being parseable partway through; nothing was written")
          return (text, done, skipped ++ [ e.name ])
      val present = f.flake-has(e.input)
      match dir
        Adding ->
          if present then
            out-warn(e.input ++ " is already a dependency")
            apply-edits(text, tl, dir, done, skipped ++ [ e.name ])
          else
            apply-edits(flake-add(f, e.input, e.ref, e.entry), tl, dir,
                        done ++ [ e.name ], skipped)
        Removing ->
          if present then
            apply-edits(flake-remove(f, e.input), tl, dir, done ++ [ e.name ], skipped)
          else
            apply-edits(text, tl, dir, done, skipped ++ [ e.name ])

fun describe-add(a : addition) : io ()
  out-item(bold(a.input) ++ "  " ++ dim(a.source))
  out-detail(a.entry)

// A bare word koki does not know is read as a GitHub `owner/repo`. When it is
// one edit away from a library in the registry, say so before a ref the user
// did not mean lands in flake.nix.
fun suggest-known(want : string) : io ()
  match lookup(want)
    Just(_) -> ()
    Nothing ->
      if explicit-ref(want) then ()
      else match str-closest(want, known-libs.map(_.name))
        Just(sug) -> out-warn("`%1` is not a known library; did you mean `%2`?"%^[want, sug])
        Nothing   -> ()

// The libs region is koki's. A line in it that is not an entry is a dependency
// koki cannot see, and removing one would leave the expression behind, so the
// command refuses rather than editing around it.
fun check-readable(f : kflake) : io bool
  val bad = flake-unreadable(f)
  if bad.is-empty then return True
  out-error("flake.nix has lines in the koki libs region that are not entries")
  bad.foreach fn(l) out-detail(l.trim)
  out-hint("rewrite them as `self.inputs.<name>...` entries, or delete them")
  False

pub fun cmd-add(p : parsed) : io int
  if p.positional.is-empty then
    out-error("`koki add` needs at least one dependency")
    out-hint("for example: koki add nel-kk, or koki add github:owner/repo")
    return 2

  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  val base = match require-flake(root)
    Nothing -> return 1
    Just(f) -> f
  if !check-readable(base) then return 1
  p.positional.foreach fn(w) suggest-known(w)
  val attr-override = p.value("attr")
  val lib-override  = p.value("library")
  val adds          = p.positional.map fn(want)
    val (input, ref, attr, style) = resolve(want, attr-override, lib-override)
    Addition(input, ref, attr, style, entry-for(input, style, attr))

  adds.foreach(describe-add)
  if p.has("dry-run") then
    out-ok("dry run: nothing was written")
    return 0

  if !p.has("yes") && term-interactive() then {
    if !prompt-confirm("Add %1 dependenc"%^[adds.length] ++ (if adds.length == 1 then "y?" else "ies?"), True) then
      out-warn("cancelled")
      return 1

  }
  val text = read-if-there(root/"flake.nix").default("")
  val edits = adds.map fn(a) Edit(a.input, a.input, a.source, a.entry)
  val (newtext, done, bad) = apply-edits(text, edits, Adding, [], [])
  if bad != [] && done.is-empty then
    out-hint("nothing was added; if flake.nix already lists it, run `nix flake lock`")
    return 1
  if !write-file(root/"flake.nix", newtext) then return 1
  if done.is-empty then
    out-warn("nothing changed")
    return 0

  out-ok("added %1 dependenc%2 to flake.nix"%^[done.length.show, if done.length == 1 then "y" else "ies"])
  out-step("updating flake.lock")
  val rc = nix-in(root, "flake lock")
  if rc != 0 then
    out-warn("`nix flake lock` failed; run it yourself to see why")
    return rc

  out-ok("flake.lock is up to date")
  0

// ---------- remove ----------

pub val remove-args : list<argdef> = [
  arg-switch("dry-run", "",  "print the change, write nothing"),
  arg-switch("yes",     "y", "do not ask for confirmation"),
]

// The input a typed name refers to. A dependency the flake already has is
// named by itself, so the name `koki info` shows is the name `koki remove`
// accepts; anything else resolves the way `koki add` resolved it.
pub fun remove-input(f : kflake, name : string) : div string
  match f.flake-deps.find(_.input-name == name)
    Just(d) -> d.input-name
    Nothing -> resolve(name, Nothing, Nothing).fst

pub fun cmd-remove(p : parsed) : io int
  if p.positional.is-empty then
    out-error("`koki remove` needs at least one dependency")
    out-hint("for example: koki remove nel-kk")
    return 2

  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  val text = match read-if-there(root / "flake.nix")
    Nothing -> return fail("cannot read flake.nix", "check that you are in a koki project")
    Just(t) -> t
  val base = match parse-flake(text)
    Nothing -> return fail("flake.nix is not a koki project", "the koki marker regions are missing")
    Just(f) -> f
  if !check-readable(base) then return 1
  // Resolved against the flake first, so the name `koki info` shows is the
  // name `koki remove` accepts.
  val edits = p.positional.map fn(n) Edit(n, remove-input(base, n), "", "")

  edits.foreach fn(e)
    if base.flake-has(e.input) then out-item("remove  " ++ bold(e.name))
    else out-warn(e.name ++ " is not a dependency of this project")

  if p.has("dry-run") then
    out-ok("dry run: nothing was written")
    return 0

  if !p.has("yes") && term-interactive() then
    if !prompt-confirm("Remove from flake.nix", True) then
      out-warn("cancelled")
      return 1

  val (newtext, done, missing) = apply-edits(text, edits, Removing, [], [])
  if done.is-empty then
    out-warn("nothing changed")
    return 1

  if !write-file(root/"flake.nix", newtext) then return 1
  out-ok("removed %1 from flake.nix"%^[done.join(", ")])
  if missing.is-empty.not then
    out-warn("%1 %2 not a dependency of this project"%^[
      missing.join(", "),
      if missing.length == 1 then "was" else "were"
    ])
  out-step("updating flake.lock")
  val rc = nix-in(root, "flake lock")
  if rc != 0 then
    out-warn("`nix flake lock` failed; run it yourself to see why")
    return rc

  out-ok("flake.lock is up to date")
  0
