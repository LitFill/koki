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
fun fd-is-tty(fd : string) : io bool
  match run-system-read("test -t " ++ fd)
    Ok(s) -> s.is-notempty
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

pub fun term-blue(s : string) : io string
  term-style(s, "\x1b[34m")

pub fun term-cyan(s : string) : io string
  term-style(s, "\x1b[36m")

pub fun term-style(s : string, codes : string) : io string
  if term-color() then codes ++ s ++ "\x1b[0m" else s

// Remove every ANSI escape sequence from `s`. Used by `--no-color` output that
// is destined for a file, and by the doctor report.
pub fun term-strip(s : string) : string
  strip-aux(s.list, [], False)

fun strip-aux(cs : list<char>, acc : list<char>, in-esc : bool) : string
  match cs
    Nil -> acc.listchar/string
    Cons(c, tl) ->
      if c == '\x1b' then strip-aux(tl, acc, True)
      elif in-esc && c == 'm' then strip-aux(tl, acc, False)
      elif in-esc then strip-aux(tl, acc, True)
      else strip-aux(tl, acc ++ [ c ], False)

// ---------- status lines ----------

// Print a line to stdout.
pub fun out-line(s : string) : io ()
  s.println

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

// Ask a question, offering `dflt` as the value shown between brackets and
// used when the user just presses enter.
pub fun prompt-ask(question : string, dflt : string) : io string
  val shown = if dflt.is-empty then " " else (" [" ++ term-dim(dflt) ++ "] ")
  (term-bold(question) ++ shown ++ ": ").print
  val answer = read-line()
  if answer.is-empty then dflt else answer

// Ask a yes/no question. An empty answer takes `dflt`; anything that is not a
// yes or a no re-asks. Koka has no `while` loop, hence the recursion.
fun confirm-loop(question : string, shown : string, dflt : bool) : io bool
  (term-bold(question) ++ " " ++ term-dim(shown) ++ ": ").print
  val answer = read-line().to-lower
  if answer == "y" || answer == "yes" then True
  elif answer == "n" || answer == "no" then False
  elif answer.is-empty then dflt
  else {
    out-detail("please answer 'y' or 'n'")
    confirm-loop(question, shown, dflt)
  }

pub fun prompt-confirm(question : string, dflt : bool) : io bool
  confirm-loop(question, if dflt then "(Y/n)" else "(y/N)", dflt)
