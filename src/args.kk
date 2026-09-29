/* A small GNU-style argument parser.
 *
 * Koka's `std/os/flags` is built around a single global flag set; koki needs a
 * different set per subcommand plus pass-through arguments, so it parses its
 * own.
 */

module src/args

import src/strutil

// One accepted option. `meta` is empty for a boolean switch and otherwise the
// placeholder shown in help, e.g. "NAME".
pub struct argdef
  long  : string
  short : string
  meta  : string
  help  : string

// The outcome of parsing one command's argument list.
pub struct parsed
  switches   : list<string>            // long names of boolean flags that were given
  options    : list<(string, string)>  // long name and value of `--opt VALUE`
  positional : list<string>
  passthru   : list<string>            // everything after a bare `--`
  errors     : list<string>

val parsed/empty = Parsed([],[],[],[],[])

// Constructors for an option table row. `meta` is empty for a switch.
pub fun arg-opt(long : string, short : string, meta : string, help : string) : argdef
  Argdef(long, short, meta, help)

pub fun arg-switch(long : string, short : string, help : string) : argdef
  Argdef(long, short, "", help)

// ---------- lookups on the result ----------

pub fun has(p : parsed, name : string) : bool
  p.switches.contains(name)

pub fun value(p : parsed, name : string) : maybe<string>
  p.options.lookup(_== name)

// A switch is on when it was given and, for the tri-state options below, when
// it was not explicitly turned off with `--no-<name>`.
pub fun flag-on(p : parsed, name : string, default : bool) : bool
  if p.has("no-" ++ name) then False
  elif p.has(name) then True
  else default

// A copy of `p` with the arguments after the command replaced. Used by
// `koki new`, which turns its name argument into the directory to create.
pub fun set-positional(p : parsed, pos : list<string>) : parsed
  p(positional = pos)

// A copy of `p` with one option's value replaced. `koki new` uses this to
// carry its name argument over to `koki init`, which takes it as `--name`.
pub fun set-opt(p : parsed, name : string, v : maybe<string> = Nothing) : parsed
  val with-no-name = p.options.filter(_.fst != name)
  match v
    Nothing -> p(options = with-no-name)
    Just(x) -> p(options = with-no-name ++ [ (name, x) ])

// ---------- lookups on the definitions ----------

fun find-long(defs : list<argdef>, name : string) : maybe<argdef>
  defs.find(_.long == name)

fun find-short(defs : list<argdef>, c : char) : maybe<argdef>
  with d <- defs.find
  !d.short.is-empty
  && d.short.list == [c]

fun all-names(defs : list<argdef>) : list<string>
  defs.map("--" ++ _.long)

// ---------- parsing ----------

fun unknown-error(defs : list<argdef>, given : string) : div string
  match str-closest(given, all-names(defs))
    Just(sug) -> "unexpected argument '" ++ given ++ "'\n  did you mean '" ++ sug ++ "'?"
    Nothing   -> "unexpected argument '" ++ given ++ "'"

// Consume the value of an option, either attached (`--name=v`) or as the next
// argument (`--name v`).
fun take-value(rest : list<string>, attached : maybe<string>) : (maybe<string>, list<string>)
  match attached
    Just(v) -> (Just(v), rest)
    Nothing ->
      match rest
        Nil -> (Nothing, Nil)
        Cons(v, tl) -> (Just(v), tl)

// Apply one argument. Returns the updated accumulator, the arguments still to
// be processed, and whether to keep going. The parser is a single loop over
// `step` because Koka cannot infer effects through mutual recursion.
fun step(defs : list<argdef>, p : parsed, args : list<string>) : div (parsed, list<string>, bool)
  match args
    Nil -> (p, Nil, False)
    Cons(arg, tl) ->
     if arg == "--" then
        // A bare `--` ends option parsing; the rest is pass-through.
        (p(passthru = p.passthru ++ tl), Nil, False)
     elif str-starts-with(arg, "--") then
        step-long(defs, p, tl, arg.str-drop(2))
     elif str-starts-with(arg, "-") && arg != "-" then
        step-short(defs, p, tl, arg.str-drop(1))
     else
        (p(positional = p.positional ++ [arg]), tl, True)

// Record an option that needs a value, or the error for one that got none.
fun accept-value(
  p        : parsed,
  rest     : list<string>,
  d        : argdef,
  attached : maybe<string>,
  spelling : string
) : (parsed, list<string>, bool)
  match take-value(rest, attached)
    (Just(v), tl) -> (p(options = p.options ++ [(d.long, v)]), tl, True)
    (Nothing, _) -> (p(errors = p.errors ++ [ "option '" ++ spelling ++ "' requires a value" ]), rest, True)

fun step-long(
  defs : list<argdef>,
  p    : parsed,
  rest : list<string>,
  body : string
) : div (parsed, list<string>, bool)
  val eq = str-split-char(body, '=')
  val name = match eq
    Cons(n, _) -> n
    Nil -> body
  val attached = match eq
    Cons(_, Cons(v, _)) -> Just(v)
    _ -> Nothing

  // `--no-x` turns the switch `x` off, matching the convention every other
  // tool follows. The prefix is stripped before the lookup, since `no-git` is
  // not itself a defined option.
  if str-starts-with(name, "no-") then
    val real = name.str-drop(3)
    match find-long(defs, real)
      Nothing -> (p(errors = p.errors ++ [ unknown-error(defs, "--" ++ name) ]), rest, True)
      Just(d) ->
        if !d.meta.is-empty then
          (p(errors = p.errors ++ [ "option '--" ++ name ++ "' does not take a value" ]), rest, True)
        else
          (p(switches = p.switches ++ [ "no-" ++ real ]), rest, True)
  else
    match find-long(defs, name)
      Nothing -> (p(errors = p.errors ++ [ unknown-error(defs, "--" ++ name) ]), rest, True)
      Just(d) ->
        if !d.meta.is-empty then
          accept-value(p, rest, d, attached, "--" ++ d.long)
        else
          (p(switches = p.switches ++ [ name ]), rest, True)

fun step-short(
  defs : list<argdef>,
  p    : parsed,
  rest : list<string>,
  body : string
) : div (parsed, list<string>, bool)
  match body.list
    Nil -> (p(errors = p.errors ++ [ unknown-error(defs, "-" ++ body) ]), rest, True)
    Cons(c, tl) ->
      match find-short(defs, c)
        Nothing -> (p(errors = p.errors ++ [ unknown-error(defs, "-" ++ c.string) ]), rest, True)
        Just(d) ->
          if !d.meta.is-empty then
            // Accept both `-tlib` and `-t=lib` for a short option.
            val tail-s   = tl.string
            val attached =
                if   tail-s.is-empty              then Nothing
                elif str-starts-with(tail-s, "=") then Just(str-drop(tail-s, 1))
                else Just(tail-s)
            accept-value(p, rest, d, attached, "-" ++ c.string)
          else
            (p(switches = p.switches ++ [d.long]), rest, True)

fun parse-go(defs : list<argdef>, p : parsed, args : list<string>) : div parsed
  val (next, rest, keep) = step(defs, p, args)
  if keep then parse-go(defs, next, rest) else next

pub fun parse-args(defs : list<argdef>, args : list<string>) : div parsed
  parse-go(defs, empty, args)

// ---------- help rendering ----------

fun short-col(d : argdef) : string
  if d.short.is-empty then "    " else "-" ++ d.short ++ " "

fun long-col(d : argdef) : string
  val name = "--" ++ d.long
  if d.meta.is-empty then name else name ++ "=" ++ d.meta

// Render the option table for a command, aligned in two columns.
pub fun usage-text(defs : list<argdef>) : string
  val width = maximum(defs.map fn(d) count(d.short-col ++ d.long-col), 20)
  defs.map fn(d)
    "  " ++ (d.short-col ++ d.long-col).pad-right(width) ++ "  " ++ d.help
  .join("\n")
