/* Argument dispatch, help text, and the command table. */

module src/cli

import src/args
import src/cmd
import src/cmd-nix
import src/cmd-project
import src/project
import src/strutil
import src/term

pub val koki-version : string = "0.1.0"

// Options every command understands. They are merged into each command's own
// table so `-h` and `--version` work wherever they are typed.
val global-args : list<argdef> = [
  arg-switch("help", "h", "show help for this command"),
  arg-switch("version", "V", "show the koki version"),
  arg-switch("color", "", "force coloured output"),
  arg-switch("no-color", "", "disable coloured output"),
  arg-switch("quiet", "q", "print only results and problems"),
  arg-switch("verbose", "v", "print more"),
]

// ---------- the command table ----------

fun mk(cmd-name : string, summary : string, defs : list<argdef>, action : parsed -> io int) : command
  Command(cmd-name, summary, defs, action)


val commands : list<command> = [
  mk("init", "create a project in the current directory", init-args, cmd-init),
  mk("new", "create a project in a new directory", new-args, cmd-new),
  mk("add", "add Koka libraries as flake inputs", add-args, cmd-add),
  mk("remove", "remove dependencies added by `koki add`", remove-args, cmd-remove),
  mk("build", "build the project with Nix", build-args, cmd-build),
  mk("run", "build and run the program", run-args, cmd-run),
  mk("check", "run the flake's checks", check-args, cmd-check),
  mk("dev", "enter the development shell", dev-args, cmd-dev),
  mk("info", "show what koki knows about this project", info-args, cmd-info),
  mk("doctor", "check the toolchain and the project", doctor-args, cmd-doctor),
]

// `help` is deliberately not in the table above: it needs the table to render
// the table, and Koka will not let a value refer to itself through a function.
// `dispatch` handles it directly instead, and `help-groups` still lists it.
fun cmd-name-of(c : command) : string
  c.name

val command-names : list<string> = commands.map(cmd-name-of)

pub fun find-command(key : string) : maybe<command>
  commands.find(fn(c) c.name == key)


// ---------- help ----------

// The command list, grouped the way every other package manager groups it.
pub struct group
  title : string
  names : list<string>

val help-groups : list<group> = [
  Group("Creating a project", [ "init", "new" ]),
  Group("Dependencies", [ "add", "remove" ]),
  Group("Building", [ "build", "run", "check", "dev" ]),
  Group("Information", [ "info", "doctor", "help" ]),
]

fun summary-of(key : string) : string
  match find-command(key)
    Just(c) -> c.summary
    Nothing -> "show this help"

fun help-row(key : string) : io string
  "  " ++ term-cyan(key.pad-right(10)) ++ summary-of(key)

fun print-usage() : io ()
  (term-bold("koki") ++ " " ++ koki-version ++ " — the Koka project manager").println
  out-blank()
  "A Koka project is a directory with a flake.nix. koki writes that file, keeps".println
  "its dependency list, and hands everything else to Nix.".println
  out-blank()
  (term-bold("Usage:")).println
  ("  " ++ term-cyan("koki") ++ " " ++ term-dim("<command>") ++ " " ++ term-dim("[options]")).println
  out-blank()
  print-groups()
  (term-bold("Options:")).println
  usage-text(global-args).println
  out-blank()
  (term-bold("Examples:")).println
  example("koki init", "start a project here")
  example("koki new my-app", "start one in ./my-app")
  example("koki add nel-kk", "add a Koka library")
  example("koki run", "build it and run it")
  out-blank()
  ("Run " ++ term-cyan("koki help <command>") ++ " for the options of one command.").println

fun print-groups() : io ()
  help-groups.foreach fn(g) {
    (term-bold(g.title)).println
    g.names.foreach fn(n) {
      (help-row(n)).println
    }
    out-blank()
  }

// One "  command          what it does" line, aligned across the block.
fun example(cmd-text : string, what : string) : io ()
  ("  " ++ term-cyan(cmd-text) ++ term-dim(" ".repeat(20 - cmd-text.list.length) ++ what)).println

// "  koki add <DEP>..." — the argument placeholder is dimmed, and a command
// that takes no arguments gets no trailing space.
fun usage-line(c : command) : io string
  val sfx = usage-suffix(c.name)
  if sfx.is-empty then "  koki " ++ c.name
  else "  koki " ++ c.name ++ " " ++ term-dim(sfx)

fun print-command-help(c : command) : io ()
  (term-bold("koki " ++ c.name) ++ " — " ++ c.summary).println
  out-blank()
  "Usage:".println
  usage-line(c).println
  if c.args.is-empty then () else {
    out-blank()
    "Options:".println
    usage-text(c.args).println
  }
  out-blank()
  (term-bold("Options common to every command:")).println
  usage-text(global-args).println

fun usage-suffix(name : string) : string
  match name
    "init" -> "[DIR]"
    "new" -> "<NAME> [DIR]"
    "add" -> "<DEP>..."
    "remove" -> "<DEP>..."
    "run" -> "[ARGS...]"
    "dev" -> "[COMMAND...]"
    "help" -> "[COMMAND]"
    _ -> ""

fun print-version() : io ()
  ("koki " ++ koki-version).println

// ---------- dispatch ----------

// An unknown command is nearly always a typo, so offer the nearest one.
fun unknown-command(name : string) : io int
  out-error("no such command: " ++ term-bold(name))
  match str-closest(name, command-names)
    Just(sug) -> out-hint("did you mean `koki " ++ sug ++ "`?")
    Nothing -> out-hint("run `koki help` to see the available commands")
  2

fun usage-error(c : command, p : parsed) : io int
  p.errors.foreach fn(e) {
    str-lines(e).foreach fn(line) {
      if str-starts-with(line, "  ") then out-detail(line.trim) else out-error(line)
    }
  }
  out-blank()
  ("Usage: koki " ++ c.name ++ " " ++ term-dim(usage-suffix(c.name))).println
  out-hint("run `koki help " ++ c.name ++ "` for the full list")
  2

// Apply the presentation flags before anything is printed.
fun apply-globals(p : parsed) : io ()
  if p.has("no-color") then force-color(False)
  elif p.has("color") then force-color(True)
  if p.has("quiet") then set-quiet(True)

pub fun run-args(argv : list<string>) : io int
  match argv
    Nil -> {
      print-usage()
      return 0
    }
    Cons(first, _) ->
      if str-starts-with(first, "-") then {
        // No command: the only sensible things are asking for the version or
        // for help. Anything else is a mistake worth naming.
        val p = parse-args(global-args, argv)
        apply-globals(p)
        if p.has("version") then {
          print-version()
          return 0
        }
        if p.errors.is-empty then {
          print-usage()
          return 0
        }
        p.errors.foreach fn(e) out-error(e)
        out-hint("run `koki help` to see the available commands")
        return 2
      } else {
        dispatch(argv)
      }

// Split `argv` into the command name and the rest, ignoring global flags that
// appear before it.
fun split-command(argv : list<string>) : (string, list<string>)
  match argv
    Nil -> ("", [])
    Cons(hd, tl) -> if str-starts-with(hd, "-") then split-command(tl) else (hd, tl)

fun dispatch(argv : list<string>) : io int
  val (name, rest) = split-command(argv)
  if name.is-empty then {
    print-usage()
    return 0
  }
  if name == "help" then return cmd-help(parse-args(global-args, rest))
  match find-command(name)
    Nothing -> unknown-command(name)
    Just(c) -> {
      val p = parse-args(c.args ++ global-args, rest)
      apply-globals(p)
      if p.has("version") then {
        print-version()
        return 0
      }
      if p.has("help") then {
        print-command-help(c)
        return 0
      }
      if !p.errors.is-empty then return usage-error(c, p)
      (c.action)(p)
    }

// `koki help` and `koki help <command>`. This is a command in its own right
// rather than a special case in `dispatch`, so it shows up in the command list
// and in tab completion like everything else.
fun cmd-help(p : parsed) : io int
  match p.positional
    Nil -> {
      print-usage()
      0
    }
    Cons(name, _) ->
      match find-command(name)
        Just(c) -> {
          print-command-help(c)
          0
        }
        Nothing -> unknown-command(name)
