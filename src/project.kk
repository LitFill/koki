/* The project model: finding a Koka project and reading/writing the parts of
 * `flake.nix` that `koki add` and `koki remove` own.
 *
 * koki does not keep a manifest of its own. `flake.nix` is the single source
 * of truth for dependencies, exactly as it is for a plain Nix project, and
 * `flake.lock` stays the lockfile. What koki adds is a pair of marker regions
 * so it can rewrite its own lines without disturbing anything else.
 *
 * Everything here is written as plain recursion over line lists: the 3.2
 * compiler drops updates when a closure that assigns to a captured `var` calls
 * another closure that does the same.
 */

module src/project

import std/os/dir
import std/os/file
import std/os/path

import src/strutil

import src/term
// ---------- the managed regions ----------

pub val inputs-start : string = "# koki:inputs:start"
pub val inputs-end : string = "# koki:inputs:end"
pub val libs-start : string = "# koki:libs:start"
pub val libs-end : string = "# koki:libs:end"

// One dependency: the flake input attribute it is registered under, and the
// expression that yields the Koka include directory it contributes.
pub struct kdep
  input-name : string
  entry      : string
  source     : string

// A marker region: its lines, plus where it sits in the file.
pub struct kblock
  body  : list<string>
  start : int
  stop  : int

// A parsed `flake.nix`.
pub struct kflake
  ls     : list<string>
  inputs : kblock
  libs   : kblock

// ---------- line plumbing ----------

fun split-at(lines : list<string>, mark : string, acc : list<string>, n : int)
    : maybe<(list<string>, list<string>, int)>
  match lines
    Nil -> Nothing
    Cons(hd, tl) ->
      if hd.trim == mark then Just((acc.reverse, tl, n))
      else split-at(tl, mark, acc ++ [ hd ], n + 1)

fun read-block(lines : list<string>, start : string, stop : string) : maybe<kblock>
  match split-at(lines, start, [], 0)
    Nothing -> Nothing
    Just((_, rest, at)) ->
      match split-at(rest, stop, [], at + 1)
        Nothing -> Nothing
        Just((body, _, stop-at)) -> Just(Kblock(body, at, stop-at))

// Replace the lines between a block's markers. The markers themselves stay:
// they are what makes the region findable again on the next pass.
fun splice(ls : list<string>, b : kblock, body : list<string>) : list<string>
  (ls.take(b.start + 1) ++ body) ++ ls.drop(b.stop)

fun render(ls : list<string>) : string
  ls.join("\n") ++ "\n"

// ---------- parsing ----------

// `    nel-kk.url = "github:LitFill/nel-kk";` -> ("nel-kk", "github:...")
fun parse-input(line : string) : maybe<(string, string)>
  val t = line.trim
  if t.is-empty || str-starts-with(t, "#") then return Nothing
  match str-before(t, '.')
    Nothing -> Nothing
    Just(input) ->
      match str-quoted(t, '"')
        Nothing -> Nothing
        Just(ref) -> Just((input, ref))

// The input name a `kokaLibsFor` entry refers to. It is looked for anywhere in
// the line rather than at the start, because the two entry styles bracket it
// differently: `self.inputs.x.kokaLibraries...` versus
// `"${self.inputs.x.packages...}/share/koka/..."`.
fun entry-input(line : string) : div maybe<string>
  val t = line.trim
  if t.is-empty || str-starts-with(t, "#") then return Nothing
  match str-after(t, "self.inputs.")
    Nothing -> Nothing
    Just(rest) -> str-before(rest, '.')

fun is-entry(line : string) : div bool
  entry-input(line).is-just

pub fun parse-flake(text : string) : maybe<kflake>
  val ls = str-lines(text)
  match read-block(ls, inputs-start, inputs-end)
    Nothing -> Nothing
    Just(inputs) ->
      match read-block(ls, libs-start, libs-end)
        Nothing -> Nothing
        Just(libs) -> Just(Kflake(ls, inputs, libs))

// ---------- reading dependencies ----------

// One `alias.url = "ref";` line in the inputs region.
pub struct inputref
  name : string
  source : string

fun push-ref(m : maybe<(string, string)>, acc : list<inputref>) : list<inputref>
  match m
    Just(r) -> [ Inputref(r.fst, r.snd) ] ++ acc
    Nothing -> acc

fun input-refs(lines : list<string>, acc : list<inputref>) : list<inputref>
  match lines
    Nil -> acc.reverse
    Cons(hd, tl) -> input-refs(tl, push-ref(parse-input(hd), acc))

// Every flake input the file declares, wherever it declares it. Reading the
// whole file rather than just the managed region means an input a user added
// by hand — `nixpkgs` above all — is still reported.
pub fun flake-input-refs(f : kflake) : list<inputref>
  input-refs(f.ls, [])

fun find-ref(refs : list<inputref>, want : string) : string
  match refs.find(fn(r) r.name == want)
    Just(r) -> r.source
    Nothing -> "(not in inputs)"

// The dependencies koki manages, in the order they appear in `kokaLibsFor`.
pub fun flake-deps(f : kflake) : div list<kdep>
  val refs = f.flake-input-refs
  f.libs.body.filter(is-entry).map fn(line)
    val name = entry-input(line).default("?")
    Kdep(name, line.trim, find-ref(refs, name))

pub fun flake-has(f : kflake, name : string) : div bool
  f.flake-deps.any fn(d) d.input-name == name

// ---------- writing dependencies ----------

fun input-line(input : string, ref : string) : string
  "    " ++ input ++ ".url = \"" ++ ref ++ "\";"

fun entry-line(entry : string) : string
  "        " ++ entry

fun drop-input(lines : list<string>, input : string) : div list<string>
  lines.filter fn(l) match parse-input(l)
    Just(r) -> r.fst != input
    Nothing -> True

fun drop-entry(lines : list<string>, input : string) : div list<string>
  lines.filter fn(l) match entry-input(l)
    Just(a) -> a != input
    Nothing -> True

// Add a dependency to both regions and return the new file text. The inputs
// region comes first in the file, so it is rewritten and re-parsed before the
// libs region is located.
pub fun flake-add(f : kflake, input : string, ref : string, entry : string) : div string
  val ls1 = splice(f.ls, f.inputs, f.inputs.body ++ [ input-line(input, ref) ])
  val ls2 = match read-block(ls1, libs-start, libs-end)
    Nothing -> ls1
    Just(libs) -> splice(ls1, libs, libs.body ++ [ entry-line(entry) ])
  render(ls2)

// Remove a dependency from both regions and return the new file text.
pub fun flake-remove(f : kflake, input : string) : div string
  val ls1 = splice(f.ls, f.inputs, drop-input(f.inputs.body, input))
  val ls2 = match read-block(ls1, libs-start, libs-end)
    Nothing -> ls1
    Just(libs) -> splice(ls1, libs, drop-entry(libs.body, input))
  render(ls2)

// ---------- locating a project ----------

// The nearest ancestor of `dir` (including `dir`) that holds `name`.
fun find-up-aux(name : string, dir : path) : io maybe<path>
  if (dir / name).is-file then return Just(dir)
  val parent = dirname(dir).path
  if parent.string == dir.string then return Nothing
  find-up-aux(name, parent)

pub fun find-up(name : string, from : path) : io maybe<path>
  find-up-aux(name, from)

// The project root: the nearest directory holding a `flake.nix`, starting from
// the real working directory so the path koki reports and hands to `nix` is
// absolute rather than relative to wherever the user happened to be.
pub fun project-root() : io maybe<path>
  find-up("flake.nix", cwd())

// The name recorded in the flake's `pname`, used to label the project.
fun pname-of(f : kflake) : maybe<string>
  val hits = f.ls.filter fn(l) str-starts-with(l.trim, "pname =")
  match hits
    Nil -> Nothing
    Cons(hd, _) -> str-quoted(hd, '"')

pub fun flake-name(f : kflake) : string
  pname-of(f).default("koka-project")

// ---------- file helpers ----------

// Read a file, treating "cannot open" as Nothing rather than an exception.
pub fun read-if-there(p : path) : io maybe<string>
  match error/try fn() { p.read-text-file }
    Ok(s) -> Just(s)
    Error(_) -> Nothing

// Write a file, reporting failure as an error message rather than a crash.
pub fun write-file(p : path, content : string) : io bool
  match error/try fn() { p.write-text-file(content) }
    Ok(_) -> True
    Error(e) -> {
      out-error("could not write " ++ p.string ++ ": " ++ e.message)
      return False
    }

// True when `text` already lists `entry` on a line of its own, which is how
// `koki doctor` checks that a generated artefact is still ignored.
pub fun gitignore-covers(text : string, entry : string) : bool
  text.str-lines.any fn(l) {
    val t = l.trim
    t == entry || t == "/" ++ entry || t == entry ++ "/"
  }
