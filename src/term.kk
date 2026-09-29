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

// Koka's stdout is block-buffered when it is not a terminal, so a progress
// line written just before a child process runs comes out *after* everything
// the child printed. Nix inherits this process's stdout, so the buffer has to
// be emptied first.
pub extern flush-out() : io ()
  c  inline "fflush(stdout);"
  js inline ""

// ---------- capability detection ----------

val color-cache : ref<global, maybe<bool>> = unsafe-total { ref(Nothing) }
val tty-cache : ref<global, maybe<bool>> = unsafe-total { ref(Nothing) }

// Ask the shell whether file descriptor `fd` is attached to a terminal.
// `test -t` says yes by exiting zero and printing nothing, so the answer is
// the exit status, not the output.
fun fd-is-tty(fd : string) : io bool
  match run-system-read("test -t " ++ fd)
    Ok(_) -> True
    Error(_) -> False

fun resolve-color() : io bool
  match get-env-value("KOKI_COLOR")
    Just("never") -> return False
    Just("always") -> return True
    _ ->
      if get-env-value("NO_COLOR").is-just then return False
      if get-env-value("CLICOLOR_FORCE").is-just then return True
      match get-env-value("TERM")
        Just("dumb") -> return False
        _ -> return fd-is-tty("1")

// Should we emit ANSI escape sequences?
pub fun term-color() : io bool
  match !color-cache
    Just(b) -> return b
    Nothing -> {
      val b = resolve-color()
      color-cache := Just(b)
      return b
    }

// Is stdin a terminal, i.e. may we ask the user questions?
pub fun term-interactive() : io bool
  match !tty-cache
    Just(b) -> return b
    Nothing -> {
      val b = fd-is-tty("0")
      tty-cache := Just(b)
      return b
    }

// Force the colour decision, for `--color` and `--no-color`.
pub fun force-color(b : bool) : io ()
  color-cache := Just(b)

val quiet-cache : ref<global, bool> = unsafe-total { ref(False) }

pub fun set-quiet(b : bool) : io ()
  quiet-cache := b

pub fun term-quiet() : read<global> bool
  !quiet-cache

// ---------- styling ----------

pub fun term-bold(s : string) : io string
  term-style(s, "\x1b[1m")

pub fun term-dim(s : string) : io string
  term-style(s, "\x1b[2m")

pub fun term-red(s : string) : io string
  term-style(s, "\x1b[31m")

pub fun term-green(s : string) : io string
  term-style(s, "\x1b[32m")

pub fun term-yellow(s : string) : io string
  term-style(s, "\x1b[33m")

pub fun term-cyan(s : string) : io string
  term-style(s, "\x1b[36m")

pub fun term-style(s : string, codes : string) : io string
  if term-color() then codes ++ s ++ "\x1b[0m" else s

// ---------- status lines ----------

// Print a blank line.
pub fun out-blank() : io ()
  "".println

// A neutral statement of fact: "  3 packages". Progress chatter is what
// `--quiet` silences; results are not.
pub fun out-item(s : string) : io ()
  if !term-quiet() then ("  " ++ s).println

// Success: a green check.
pub fun out-ok(s : string) : io ()
  (term-green("✔") ++ " " ++ s).println

// Progress or an action about to happen: a cyan arrow.
pub fun out-step(s : string) : io ()
  if !term-quiet() then (term-cyan("→") ++ " " ++ s).println

// Something worth knowing but not fatal: a yellow bang.
pub fun out-warn(s : string) : io ()
  (term-yellow("!") ++ " " ++ s).println

// Secondary detail attached to the line above.
pub fun out-detail(s : string) : io ()
  if !term-quiet() then ("  " ++ term-dim(s)).println

// A fatal problem. Always on stderr, always red, never colourless.
pub fun out-error(s : string) : io ()
  (term-red(term-bold("error")) ++ ": " ++ s).println

// The remedy for the line above.
pub fun out-hint(s : string) : io ()
  ("  " ++ term-cyan("help") ++ ": " ++ s).println

// A titled block, used for `koki info` and the `next steps` footer.
pub fun out-heading(s : string) : io ()
  (term-bold(s)).println

// ---------- prompts ----------
fun read-line() : io string
  match error/try fn() { readline() }
    Ok(s) -> s.trim
    Error(_) -> ""

// A prompt ends without a newline, so it sits in stdout's buffer while the
// program blocks on input and the user is looking at an apparently hung
// process. Every prompt therefore flushes before it waits.
fun ask-line(question : string, shown : string) : io string
  (term-bold(question) ++ shown ++ ": ").print
  flush-out()
  read-line()

// Ask a question, offering `dflt` as the value shown between brackets and
// used when the user just presses enter.
pub fun prompt-ask(question : string, dflt : string) : io string
  val shown = if dflt.is-empty then " " else (" [" ++ term-dim(dflt) ++ "] ")
  val answer = ask-line(question, shown)
  if answer.is-empty then dflt else answer

// Does this reply settle a yes/no question? An empty line settles it too — the
// caller reads that as "take the default" — so only a reply that is neither a
// yes nor a no leaves the question open.
pub fun prompt-settles(answer : string) : bool
  match answer
    "y" -> True
    "yes" -> True
    "n" -> True
    "no" -> True
    "" -> True
    _ -> False

// Ask a yes/no question. An empty answer takes `dflt`; anything else that is
// not a yes or a no re-asks. The loop turns on whether the question has been
// answered, not on the answer, so that the empty string a fresh `var` holds is
// not mistaken for the user pressing enter.
pub fun prompt-confirm(question : string, dflt : bool) : io bool
  val shown = if dflt then "(Y/n)" else "(y/N)"
  var answer := ""
  var answered := False
  while(fn() !answered, fn() {
    answer := ask-line(question, " " ++ term-dim(shown)).to-lower
    answered := prompt-settles(answer)
    if !answered then out-detail("please answer 'y' or 'n'")
  })
  match answer
    "y" -> True
    "yes" -> True
    "n" -> False
    "no" -> False
    _ -> dflt
