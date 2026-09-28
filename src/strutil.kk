/* String helpers used across the koki CLI.
 *
 * Koka imports bring names in unqualified, so every export here is prefixed
 * with `str-` to keep call sites unambiguous and greppable.
 *
 * Everything below is written as plain recursion rather than as a `var`
 * mutated inside a `foreach` closure: the 3.2 compiler drops updates when a
 * closure that assigns to a captured `var` calls another closure that does the
 * same, which silently turns these helpers into no-ops.
 */

module src/strutil

// ---------- numeric ----------

pub fun str-min(a : int, b : int) : int
  if a <= b then a else b

pub fun str-max(a : int, b : int) : int
  if a >= b then a else b

// ---------- classification ----------

pub fun str-is-alnum(c : char) : bool
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

pub fun str-is-upper(c : char) : bool
  c >= 'A' && c <= 'Z'

// ---------- predicates ----------

pub fun str-starts-with(s : string, pfx : string) : bool
  s.list.take(pfx.list.length) == pfx.list

pub fun str-ends-with(s : string, sfx : string) : bool
  val ss = sfx.list
  val total = s.list.length
  if total < ss.length then False
  else s.list.drop(total - ss.length) == ss

// The text after the first occurrence of `needle`, or Nothing when it does not
// occur. Used to pick a dependency's input name out of an expression, which
// may have a prefix, a suffix, or both.
pub fun str-after(s : string, needle : string) : div maybe<string>
  after-aux(s.list, needle.list, 0)

fun after-aux(cs : list<char>, needle : list<char>, skip : int) : div maybe<string>
  val at = cs.drop(skip)
  if at.take(needle.length) == needle then
    Just(at.drop(needle.length).listchar/string)
  elif skip >= cs.length then
    Nothing
  else
    after-aux(cs, needle, skip + 1)

// ---------- list helpers ----------

// The last element, or `dflt` for an empty list.
pub fun str-last(xs : list<a>, dflt : a) : a
  match xs
    Nil -> dflt
    Cons(hd, tl) -> str-last(tl, hd)

// The element at index `i`, or `dflt` when out of range.
pub fun nth(xs : list<a>, i : int, dflt : a) : div a
  match (i, xs)
    (0, Cons(hd, _)) -> hd
    (_, Cons(_, tl)) -> nth(tl, i - 1, dflt)
    _ -> dflt

// Everything before the first `q`, or Nothing when `q` does not occur.
pub fun str-before(s : string, q : char) : maybe<string>
  before-aux(s.list, q, [])

fun before-aux(cs : list<char>, q : char, acc : list<char>) : maybe<string>
  match cs
    Nil -> Nothing
    Cons(c, tl) -> if c == q then Just(acc.listchar/string) else before-aux(tl, q, acc ++ [ c ])

// The text between the first pair of `q` characters, or Nothing when the
// string does not contain exactly one quoted run. Used to pull values out of
// Nix attribute lines.
pub fun str-quoted(s : string, q : char) : maybe<string>
  match str-split-char(s, q)
    Cons(_, Cons(inner, Cons(_, Nil))) -> Just(inner)
    _ -> Nothing

// ---------- splitting ----------

// Split on a single separator character, dropping empty fields.
pub fun str-split-char(s : string, sep : char) : list<string>
  split-aux(s.list, sep, [], [])

// `out` is kept reversed and flipped once at the end, so building a list costs
// one pass instead of one append per field.
fun split-aux(cs : list<char>, sep : char, cur : list<char>, out : list<string>) : list<string>
  match cs
    Nil -> push-field(cur, out).reverse
    Cons(c, tl) ->
      if c == sep then split-aux(tl, sep, [], push-field(cur, out))
      else split-aux(tl, sep, cur ++ [ c ], out)

fun push-field(cur : list<char>, out : list<string>) : list<string>
  if cur == [] then out else [ cur.listchar/string ] ++ out

// Split into lines, dropping the empty final field a trailing newline leaves
// behind. Interior blank lines are preserved.
pub fun str-lines(s : string) : list<string>
  val ls = s.lines
  match ls.reverse
    Cons(hd, tl) -> if hd.is-empty then tl.reverse else ls
    Nil -> Nil

// ---------- case conversion ----------

// Split a human phrase into lowercase alphanumeric words: "Hello World",
// "hello_world" and "helloWorld" all yield ["hello","world"].
pub fun str-words(s : string) : list<string>
  words-aux(s.list, [], [])

fun words-aux(cs : list<char>, cur : list<char>, out : list<string>) : list<string>
  match cs
    Nil -> flush-lower(cur, out).reverse
    Cons(c, tl) -> {
      if !str-is-alnum(c) then words-aux(tl, [], flush-lower(cur, out))
      elif str-is-upper(c) && cur != [] then words-aux(tl, [ c ], flush-lower(cur, out))
      else words-aux(tl, cur ++ [ c ], out)
    }

fun flush-lower(cur : list<char>, out : list<string>) : list<string>
  if cur == [] then out else [ cur.listchar/string.to-lower ] ++ out

// "Hello World" -> "hello-world"
pub fun str-kebab(s : string) : string
  s.str-words.join("-")

// "Hello World" -> "hello_world"
pub fun str-snake(s : string) : string
  s.str-words.join("_")

// Strip leading and trailing dashes.
fun trim-dashes-front(cs : list<char>) : list<char>
  match cs
    Cons(c, tl) -> if c == '-' then trim-dashes-front(tl) else cs
    Nil -> cs

fun trim-dashes-back(cs : list<char>) : list<char>
  match cs.reverse
    Cons(c, tl) -> if c == '-' then tl.reverse else cs
    Nil -> cs

pub fun str-trim-dashes(s : string) : string
  trim-dashes-back(trim-dashes-front(s.list)).listchar/string

// Everything after the first `n` characters.
pub fun str-tail(s : string, n : int) : string
  s.list.drop(n).listchar/string

// ---------- validation ----------

// A project name must be usable as a directory name, a Nix attribute and a
// derivation `pname`: lowercase alphanumerics joined by single dashes.
pub fun str-valid-name(s : string) : bool
  if s.is-empty then return False
  if s.str-words.is-empty then return False
  // Valid names round-trip through `str-kebab` unchanged, which rules out
  // uppercase, spaces, punctuation and leading/trailing/repeated dashes.
  str-kebab(s) == s

// Turn arbitrary user input ("My Cool App!") into a valid project name.
pub fun str-sanitize-name(s : string) : string
  val cleaned = str-kebab(s).str-trim-dashes
  if cleaned.is-empty then "koka-app" else cleaned

// ---------- distances ----------

// One row of the Levenshtein matrix, computed left to right. `left` is the cell
// immediately to the left, `diag` the cell above and to the left; carrying them
// through the recursion keeps every row linear.
fun lev-aux(prev : list<int>, x : char, ys : list<char>, j : int,
            left : int, diag : int, out : list<int>) : div list<int>
  match ys
    Nil -> out
    Cons(y, tl) -> {
      val above = nth(prev, j, 0)
      val cell = str-min(above + 1, str-min(left + 1, diag + (if x == y then 0 else 1)))
      lev-aux(prev, x, tl, j + 1, cell, above, out ++ [ cell ])
    }

fun lev-row(prev : list<int>, x : char, ys : list<char>) : div list<int>
  lev-aux(prev, x, ys, 0, 0, 0, [])

// The first row of the matrix: 0, 1, 2, ... n.
fun index-row(n : int) : div list<int>
  if n <= 0 then [ 0 ] else index-row(n - 1) ++ [ n ]

fun distance-rows(xs : list<char>, ys : list<char>, prev : list<int>) : div int
  match xs
    Nil -> str-last(prev, 0)
    Cons(x, tl) -> distance-rows(tl, ys, lev-row(prev, x, ys))

// Levenshtein distance, used for "did you mean ...?" suggestions.
pub fun str-distance(a : string, b : string) : div int
  val xs = a.list
  val ys = b.list
  // With an empty row or column the matrix degenerates, so answer directly
  // rather than walk a row that carries no information.
  if ys == [] then xs.length
  elif xs == [] then ys.length
  else distance-rows(xs, ys, index-row(ys.length))

// A suggestion is only worth making when it is within a third of the word's
// length, and never further than two edits.
fun suggest-cutoff(word : string) : int
  str-max(2, word.list.length / 3)

fun closest-aux(cs : list<string>, word : string, best : maybe<string>, best-d : int) : div maybe<string>
  match cs
    Nil -> if best-d <= suggest-cutoff(word) then best else Nothing
    Cons(c, tl) -> {
      val d = str-distance(word, c)
      if d < best-d then closest-aux(tl, word, Just(c), d)
      else closest-aux(tl, word, best, best-d)
    }

// Pick the candidate closest to `word`, if any is close enough. Ties resolve to
// the first candidate in the list.
pub fun str-closest(word : string, candidates : list<string>) : div maybe<string>
  closest-aux(candidates, word, Nothing, 1_000_000)

// The values of the `Just` entries, dropping the `Nothing`s.
pub fun justs(xs : list<maybe<a>>) : list<a>
  match xs
    Nil -> []
    Cons(Just(hd), tl) -> [ hd ] ++ justs(tl)
    Cons(Nothing, tl) -> justs(tl)

// ---------- shell ----------

fun safe-char(c : char) : bool
  str-is-alnum(c) || c == '-' || c == '_' || c == '.' || c == '/'
    || c == '=' || c == ':' || c == ',' || c == '+' || c == '@' || c == '%'

fun all-safe(cs : list<char>) : bool
  match cs
    Nil -> True
    Cons(c, tl) -> if safe-char(c) then all-safe(tl) else False

// Quote one argument for /bin/sh. Pass-through arguments reach a shell as one
// joined string, so an argument containing a space or a quote has to be
// protected here or `koki dev -- sh -c '...'` arrives as several words.
pub fun str-shquote(s : string) : string
  if all-safe(s.list) then s
  else "'" ++ s.replace-all("'", "'\\''") ++ "'"

// Quote every argument and join them with single spaces.
pub fun str-shjoin(args : list<string>) : string
  args.map(str-shquote).join(" ")
