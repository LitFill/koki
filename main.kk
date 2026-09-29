/* koki — the Koka project manager.
 *
 * A Koka project is a directory with a flake.nix. koki writes that file, keeps
 * its dependency list, and hands the actual building to Nix.
 */

module main

import std/os/env

import src/cli
import src/term

// A `main` that returns an int has its return value printed and then used as
// the exit status. koki wants the status without the print, so `main` returns
// unit and the status is set here.
extern exit-now(code : int) : io ()
  c  inline "exit(kk_smallint_from_integer(#1));"
  js inline "process.exit(#1);"

fun main() : io ()
  val rc = run-args(get-args())
  if rc != 0 then exit-now(rc)
