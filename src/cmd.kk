/* The shape of a subcommand, plus the bits every subcommand needs. */

module src/cmd

import std/os/env
import std/os/file
import std/os/path
import std/os/process

import src/args
import src/project
import src/strutil
import src/term

// One subcommand: how it is named, what it does, what it accepts, and what it
// does with the arguments once they are parsed.
pub struct command
  name    : string
  summary : string
  args    : list<argdef>
  action  : parsed -> io int

// ---------- running other tools ----------


// Is `exe` on the PATH? `command -v` prints the path it found, so the output
// is the answer rather than something to redirect away.
pub fun have-exe(exe : string) : io bool
  match run-system-read("command -v " ++ exe ++ " 2>/dev/null")
    Ok(s) -> s.is-notempty
    Error(_) -> False

// The first line of `cmd`'s output, for version banners. `koka --version` ends
// with its licence text, so this takes the first line rather than the last.
pub fun first-line-of(cmd : string) : io string
  match run-system-read(cmd)
    Ok(s) -> first-nonempty(s.str-lines)
    Error(_) -> ""

fun first-nonempty(lines : list<string>) : string
  match lines
    Nil -> ""
    Cons(hd, tl) -> if hd.trim.is-empty then first-nonempty(tl) else hd.trim

// Run a child with this process's stdout attached, so its output and its exit
// status are the user's own. The parent's buffer is flushed first, or the
// progress line printed just before the child would land after the child's
// output.
pub fun run-child(cmd : string) : io int
  flush-out()
  run-system(cmd)

// The `error:` / `help:` pair that ends a failed command.
pub fun fail(message : string, help : string) : io int
  out-error(message)
  out-hint(help)
  1

// Run `nix` with `args` in the project directory. The directory is quoted for
// the shell because a path is allowed to contain a space.
pub fun nix-in(root : path, args : string) : io int
  run-child("cd " ++ str-shquote(root.string) ++ " && nix " ++ args)

// Resolve the project root, or explain how to make one.
pub fun require-project() : io maybe<path>
  match project-root()
    Nothing -> {
      out-error("no flake.nix here, and none in any parent directory")
      out-hint("run `koki init` to create a project, or `koki new <name>` for a new one")
      return Nothing
    }
    Just(root) -> return Just(root)

// Read and parse the project's flake, or explain what is wrong with it.
pub fun require-flake(root : path) : io maybe<kflake>
  val text = read-if-there(root / "flake.nix")
  match text
    Nothing -> {
      out-error("cannot read " ++ (root / "flake.nix").string)
      return Nothing
    }
    Just(t) ->
      match parse-flake(t)
        Nothing -> {
          out-error((root / "flake.nix").string ++ " is not a koki project")
          out-detail("koki manages two marked regions and cannot find them")
          out-detail("expected " ++ inputs-start ++ " / " ++ inputs-end)
          out-detail("and      " ++ libs-start ++ " / " ++ libs-end)
          out-hint("regenerate the file with `koki init --force`, or add the markers by hand")
          return Nothing
        }
        Just(f) -> return Just(f)

// The block a scaffolding command ends with, in the shape everyone recognises
// from `npm init` and `cargo new`.
pub fun next-steps(steps : list<(string, string)>) : io ()
  out-blank()
  out-heading("Next steps:")
  steps.foreach-indexed fn(i, step) {
    val (what, cmd) = step
    val n = (i + 1).show
    ("  " ++ term-cyan(n ++ ".") ++ "  " ++ what).println
    ("      " ++ term-green(cmd)).println
  }
  out-blank()
