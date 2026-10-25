/* Terminal output for the koki CLI: colour handling, status lines, prompts.
 *
 * Colour is decided once per process and cached, so piping `koki` into a file
 * or a CI log never emits escape codes.
 */

module src/term

import std/core/unsafe
import std/os/env
import std/os/process
import std/os/readline

import util

// Koka's stdout is block-buffered when it is not a terminal, so a progress
// line written just before a child process runs comes out *after* everything
// the child printed. Nix inherits this process's stdout, so the buffer has to
// be emptied first.
pub extern flush-out() : console ()
  c  inline "fflush(stdout);"
  js inline ""

// ---------- capability detection ----------

val color-cache : ref<global, maybe<bool>> = unsafe-total { ref(Nothing) }

// Ask the shell whether file descriptor `fd` is attached to a terminal.
// `test -t` says yes by exiting zero and printing nothing, so the answer is
// the exit status, not the output.
fun fd-is-tty(fd : string) : io bool
  run-system("test -t " ++ fd) == 0

fun resolve-color() : io bool
  match get-env-value("KOKI_COLOR")
    Just("never")  -> return False
    Just("0")      -> return False
    Just("always") -> return True
    Just("1")      -> return True
    _ ->
      if get-env-value("NO_COLOR").is-just       then return False
      if get-env-value("CLICOLOR_FORCE").is-just then return True
      match get-env-value("TERM")
        Just("dumb") -> return False
        _            -> return fd-is-tty("1")

// Should we emit ANSI escape sequences?
pub fun term-color() : io bool
  match !color-cache
    Just(b) -> b
    Nothing ->
      val b = resolve-color()
      color-cache := Just(b)
      b

// Asking the shell spawns a process, so the answer is computed at most once.
val tty : delayed<io, bool> = delay { fd-is-tty("0") }

// Is stdin a terminal, i.e. may we ask the user questions?
pub fun term-interactive() : io bool
  tty.force

// Force the colour decision, for `--color` and `--no-color`.
pub fun force-color(b : bool) : io ()
  color-cache := Just(b)

val quiet-cache : ref<global, bool> = unsafe-total { ref(False) }

pub fun set-quiet(b : bool) : io ()
  quiet-cache := b

pub fun term-quiet() : read<global> bool
  (!quiet-cache)

// ---------- styling ----------

pub fun style(s : string, codes : string) : io string
  if term-color() then codes ++ s ++ "\x1b[0m" else s

pub fun bold   (s : string) : io string { s.style("\x1b[1m")  }
pub fun dim    (s : string) : io string { s.style("\x1b[2m")  }
pub fun red    (s : string) : io string { s.style("\x1b[31m") }
pub fun green  (s : string) : io string { s.style("\x1b[32m") }
pub fun yellow (s : string) : io string { s.style("\x1b[33m") }
pub fun cyan   (s : string) : io string { s.style("\x1b[36m") }

// ---------- status lines ----------

// Print a blank line.
pub fun out-blank() : console ()
  "".println

// A neutral statement of fact: "  3 packages". Progress chatter is what
// `--quiet` silences; results are not.
pub fun out-item(s : string) : io ()
  if !term-quiet() then println("  " ++ s)

// Success: a green check.
pub fun out-ok(s : string) : io ()
  println("✔".green ++ " " ++ s)

// Progress or an action about to happen: a cyan arrow.
pub fun out-step(s : string) : io ()
  if !term-quiet() then println("→".cyan ++ " " ++ s)

// Something worth knowing but not fatal: a yellow bang.
pub fun out-warn(s : string) : io ()
  println("!".yellow ++ " " ++ s)

// Secondary detail attached to the line above.
pub fun out-detail(s : string) : io ()
  if !term-quiet() then println("  " ++ dim(s))

// A fatal problem. Always on stderr, always red, never colourless.
pub fun out-error(s : string) : io ()
  println("error".bold.red ++ ": " ++ s)

// The remedy for the line above.
pub fun out-hint(s : string) : io ()
  println("  " ++ "help".cyan ++ ": " ++ s)

// A titled block, used for `koki info` and the `next steps` footer.
pub fun out-heading(s : string) : io ()
  s.bold.println

// ---------- prompts ----------
fun read-line() : io string
  match try({ readline() })
    Ok(s)    -> s.trim
    Error(_) -> ""

// A prompt ends without a newline, so it sits in stdout's buffer while the
// program blocks on input and the user is looking at an apparently hung
// process. Every prompt therefore flushes before it waits.
fun ask-line(question : string, shown : string) : io string
  print(question.bold ++ shown ++ ": ")
  flush-out()
  read-line()

// Ask a question, offering default `dflt` as the value shown between brackets
// and used when the user just presses enter.
pub fun prompt-ask(question : string, dflt : string) : io string
  val shown  = if dflt.is-empty then " " else (" [" ++ dflt.dim ++ "] ")
  ask-line(question, shown) || dflt

// Does this reply settle a yes/no question? An empty line settles it too — the
// caller reads that as "take the default" — so only a reply that is neither a
// yes nor a no leaves the question open.
pub fun prompt-settles(answer : string) : bool
  match answer
    "y"   -> True
    "yes" -> True
    "n"   -> True
    "no"  -> True
    ""    -> True
    _     -> False

// Ask a yes/no question. An empty answer takes default `dflt`; anything else
// that is not a yes or a no re-asks. The loop turns on whether the question
// has been answered, not on the answer, so that the empty string a fresh `var`
// holds is not mistaken for the user pressing enter.
pub fun prompt-confirm(question : string, dflt : bool) : io bool
  val shown     = if dflt then "(Y/n)" else "(y/N)"
  var answer   := ""
  var answered := False
  while { !answered }
    answer   := ask-line(question, " " ++ shown.dim).to-lower
    answered := prompt-settles(answer)
    if !answered then out-detail("please answer 'y' or 'n'")

  match answer
    "y"   -> True
    "yes" -> True
    "n"   -> False
    "no"  -> False
    _     -> dflt
