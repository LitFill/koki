/* Commands that create a project or change its dependencies. */

module src/cmd-project

import std/os/dir
import std/os/file
import std/os/path
import std/os/process

import src/args
import src/cmd
import src/project
import src/registry
import src/strutil
import src/templates
import src/term

// ---------- shared plumbing ----------

fun safe-dir(p : path) : io bool
  match error/try fn() { p.is-directory }
    Ok(b) -> b
    Error(_) -> False

fun non-empty-dir(p : path) : io bool
  match error/try fn() { list-directory(p).length > 0 }
    Ok(b) -> b
    Error(_) -> False

fun this-year() : io string
  match run-system-read("date +%Y")
    Ok(s) -> last(s.str-lines).default("")
    Error(_) -> "2026"

// ---------- init ----------

pub val init-args : list<argdef> = [
  arg-opt("name", "n", "NAME", "project name (default: the directory name)"),
  arg-opt("template", "t", "KIND", "bin, lib or test (default: bin)"),
  arg-opt("description", "d", "TEXT", "one-line description"),
  arg-opt("author", "a", "NAME", "copyright holder"),
  arg-opt("license", "l", "TEXT", "license name (default: MIT)"),
  arg-opt("pkg-version", "", "VER", "starting version (default: 0.1.0)"),
  arg-switch("yes", "y", "take every default without asking"),
  arg-switch("force", "f", "overwrite files that already exist"),
  arg-switch("git", "", "run `git init` (default: yes; --no-git to skip)"),
  arg-switch("dry-run", "", "print what would be created, write nothing"),
]

val template-kinds : list<string> = [ "bin", "lib", "test" ]

// The name a project gets when nothing else says otherwise.
fun default-name(dir : string) : string
  str-sanitize-name(if dir.is-empty || dir == "." then "koka-app" else dir)

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
  val ask = !p.has("yes") && term-interactive()
  val name = p.value("name").default(if ask then prompt-ask("Project name", default-name(dir)) else default-name(dir))
  val kind = p.value("template").default(if ask then prompt-ask("Template (bin, lib, test)", "bin") else "bin")
  val desc = p.value("description").default(if ask then prompt-ask("Description", "A Koka project") else "A Koka project")
  val author = p.value("author").default(if ask then prompt-ask("Author", "Anonymous") else "Anonymous")
  val lic = p.value("license").default(if ask then prompt-ask("License", "MIT") else "MIT")
  val ver = p.value("pkg-version").default(if ask then prompt-ask("Version", "0.1.0") else "0.1.0")
  Answers(name, kind, desc, author, lic, ver)

fun check-kind(kind : string) : io bool
  if template-kinds.contains(kind) then return True
  out-error("unknown template '" ++ kind ++ "'")
  out-hint("choose one of: " ++ template-kinds.join(", "))
  return False

// Write one template file, reporting what happened.
fun emit(root : path, f : newfile, dry : bool) : io bool
  if dry then {
    out-item("create  " ++ f.path)
    return True
  }
  if !write-file(root / f.path, f.body) then return False
  out-item("create  " ++ f.path)
  True

fun emit-all(root : path, files : list<newfile>, dry : bool) : io bool
  match files
    Nil -> return True
    Cons(f, tl) -> {
      if !emit(root, f, dry) then return False
      emit-all(root, tl, dry)
    }

pub fun cmd-init(p : parsed) : io int
  val dir = last(p.positional).default(".")
  val root = dir.path
  val a = ask-missing(p, dir)
  val name = a.name
  val kind = a.kind
  if !check-kind(kind) then return 2
  if !str-valid-name(name) then {
    out-error("'" ++ name ++ "' is not a usable project name")
    out-hint("use lowercase letters, digits and single dashes, like `my-app`")
    return 2
  }
  val dry = p.has("dry-run")
  if !dry && safe-dir(root) && !p.has("force") && non-empty-dir(root) then {
    out-error(root.string ++ " is not empty")
    out-hint("pass --force to write into it anyway, or name another directory")
    return 1
  }
  if !dry then {
    match error/try fn() { root.ensure-dir }
      Ok(_) -> ()
      Error(e) -> {
        out-error("cannot create " ++ root.string ++ ": " ++ e.message)
        return 1
      }
  }
  val s = Settings(name, a.desc, a.version, a.author, a.license, this-year(), kind)
  out-step("creating a " ++ kind ++ " project in " ++ root.string)
  if !emit-all(root, template-files(s), dry) then return 1
  if dry then {
    out-ok("dry run: nothing was written")
    return 0
  }
  if flag-on(p, "git", True) then {
    // Nix reads a flake through git, so a repository whose files are still
    // untracked makes `koki build` fail with a message about tracking rather
    // than about the build. Staging here is enough; the commit is the user's.
    val quoted = str-shquote(root.string)
    if run-system("git init -q " ++ quoted) == 0 then {
      if run-system("git -C " ++ quoted ++ " add -A") == 0 then
        out-ok("initialised a git repository and staged the files")
      else
        out-warn("could not stage the files; `nix build` will not see them until they are added to git")
    } else {
      out-warn("could not run `git init`; the rest of the project is complete")
    }
  }
  out-ok("created " ++ term-bold(name) ++ " (" ++ kind ++ ")")
  // The commit step only makes sense when there is a repository to commit to.
  val commit = if flag-on(p, "git", True)
                 then [ ("commit it", "git add -A && git commit -m 'initial commit'") ]
                 else []
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
  if p.positional.is-empty then {
    out-error("`koki new` needs a name")
    out-hint("for example: koki new my-app")
    return 2
  }
  val name = last(p.positional).default("")
  val dir = p.positional.@index(1).default(name)
  cmd-init(set-opt(set-positional(p, [ dir ]), "name", Just(name)))

// ---------- add ----------

pub val add-args : list<argdef> = [
  arg-opt("attr", "", "NAME", "flake output attribute holding the library"),
  arg-opt("library", "", "NAME", "name under `kokaLibraries` in that flake"),
  arg-switch("dry-run", "", "print the change, write nothing"),
  arg-switch("yes", "y", "do not ask for confirmation"),
]

// One dependency resolved to the four things the flake needs to record it.
pub struct addition
  input : string
  source : string
  attr  : string
  style : string
  entry : string

// Apply a list of additions to the flake text, one at a time so each one sees
// the file the previous one produced.
fun apply-adds(text : string, adds : list<addition>, done : list<string>, bad : list<string>)
    : io (string, list<string>, list<string>)
  match adds
    Nil -> return (text, done, bad)
    Cons(a, tl) -> {
      val f = match parse-flake(text)
        Nothing -> {
          out-error("flake.nix stopped being parseable partway through; nothing was written")
          return (text, done, bad ++ [ a.input ])
        }
        Just(x) -> x
      if f.flake-has(a.input) then {
        out-warn(a.input ++ " is already a dependency")
        apply-adds(text, tl, done, bad ++ [ a.input ])
      } else {
        apply-adds(flake-add(f, a.input, a.source, a.entry), tl, done ++ [ a.input ], bad)
      }
    }

fun describe-add(a : addition) : io ()
  out-item(term-bold(a.input) ++ "  " ++ term-dim(a.source))
  out-detail(a.entry)

pub fun cmd-add(p : parsed) : io int
  if p.positional.is-empty then {
    out-error("`koki add` needs at least one dependency")
    out-hint("for example: koki add nel-kk, or koki add github:owner/repo")
    return 2
  }
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  val base = match require-flake(root)
    Nothing -> return 1
    Just(f) -> f
  val attr-override = p.value("attr")
  val lib-override = p.value("library")
  val adds = p.positional.map fn(want) {
    val (input, ref, attr, style) = resolve(want, attr-override, lib-override)
    Addition(input, ref, attr, style, entry-for(input, style, attr))
  }
  adds.foreach(fn(a) describe-add(a))
  if p.has("dry-run") then {
    out-ok("dry run: nothing was written")
    return 0
  }
  if !p.has("yes") && term-interactive() then {
    if !prompt-confirm("Add " ++ adds.length.show ++ " dependenc" ++ (if adds.length == 1 then "y?" else "ies?"), True) then {
      out-warn("cancelled")
      return 1
    }
  }
  val text = read-if-there(root / "flake.nix").default("")
  val (newtext, done, bad) = apply-adds(text, adds, [], [])
  if bad != [] && done.is-empty then return 1
  if !write-file(root / "flake.nix", newtext) then return 1
  if done.is-empty then {
    out-warn("nothing changed")
    return 0
  }
  out-ok("added " ++ done.length.show ++ " dependenc" ++ (if done.length == 1 then "y" else "ies") ++ " to flake.nix")
  out-step("updating flake.lock")
  val rc = nix-in(root, "flake lock")
  if rc != 0 then {
    out-warn("`nix flake lock` failed; run it yourself to see why")
    return rc
  }
  out-ok("flake.lock is up to date")
  0

// ---------- remove ----------

pub val remove-args : list<argdef> = [
  arg-switch("dry-run", "", "print the change, write nothing"),
  arg-switch("yes", "y", "do not ask for confirmation"),
]

pub fun apply-removes(text : string, names : list<string>, done : list<string>, missing : list<string>)
    : io (string, list<string>, list<string>)
  match names
    Nil -> return (text, done, missing)
    Cons(n, tl) -> {
      // `koki add` files a dependency under the name `resolve` derives from
      // the spelling the user typed, so `koki add LitFill/nel-kk` lands as the
      // input `nel-kk`. Resolving the same way here is what makes the name a
      // dependency was added with also the name it can be removed with.
      val input = resolve(n, Nothing, Nothing).fst
      val f = match parse-flake(text)
        Nothing -> {
          out-error("flake.nix stopped being parseable partway through; nothing was written")
          return (text, done, missing ++ [ n ])
        }
        Just(x) -> x
      if f.flake-has(input) then
        apply-removes(flake-remove(f, input), tl, done ++ [ n ], missing)
      else
        apply-removes(text, tl, done, missing ++ [ n ])
    }

pub fun cmd-remove(p : parsed) : io int
  if p.positional.is-empty then {
    out-error("`koki remove` needs at least one dependency")
    out-hint("for example: koki remove nel-kk")
    return 2
  }
  val root = match require-project()
    Nothing -> return 1
    Just(r) -> r
  val text = match read-if-there(root / "flake.nix")
    Nothing -> return fail("cannot read flake.nix", "check that you are in a koki project")
    Just(t) -> t
  val base = match parse-flake(text)
    Nothing -> return fail("flake.nix is not a koki project", "the koki marker regions are missing")
    Just(f) -> f
  // Resolved the same way `apply-removes` resolves, so the listing agrees with
  // what actually gets removed.
  p.positional.foreach fn(n) {
    if base.flake-has(resolve(n, Nothing, Nothing).fst) then out-item("remove  " ++ term-bold(n))
    else out-warn(n ++ " is not a dependency of this project")
  }
  if p.has("dry-run") then {
    out-ok("dry run: nothing was written")
    return 0
  }
  if !p.has("yes") && term-interactive() then {
    if !prompt-confirm("Remove from flake.nix", True) then {
      out-warn("cancelled")
      return 1
    }
  }
  val (newtext, done, missing) = apply-removes(text, p.positional, [], [])
  if done.is-empty then {
    out-warn("nothing changed")
    return 0
  }
  if !write-file(root / "flake.nix", newtext) then return 1
  out-ok("removed " ++ done.join(", ") ++ " from flake.nix")
  if missing.is-empty then ()
  else out-warn(missing.join(", ") ++ " " ++ (if missing.length == 1 then "was" else "were")
                ++ " not a dependency of this project")
  out-step("updating flake.lock")
  val rc = nix-in(root, "flake lock")
  if rc != 0 then {
    out-warn("`nix flake lock` failed; run it yourself to see why")
    return rc
  }
  out-ok("flake.lock is up to date")
  0
