/* The test suite for koki's own logic.
 *
 * Koka has no test runner, so this is a plain program: it runs a list of
 * named checks, prints one line each, and exits non-zero if any failed. The
 * `checks` derivation in flake.nix builds and runs it, so `koki check` fails
 * when this fails.
 */

module test/run

import src/args
import src/project
import src/registry
import src/strutil
import src/templates
import src/term

// A `main` that returns an int has its value printed; exit explicitly instead.
extern exit-now(code : int) : io ()
  c  inline "exit(kk_smallint_from_integer(#1));"
  js inline "process.exit(#1);"

struct result
  name : string
  ok   : bool

fun check(name : string, ok : bool) : result
  Result(name, ok)

fun count-failed(rs : list<result>) : div int
  match rs
    Nil -> 0
    Cons(hd, tl) -> (if hd.ok then 0 else 1) + count-failed(tl)

// ---------- strutil ----------

// A function rather than a value: `distance` and `closest` are `div`, and a
// top-level value cannot carry that effect.
fun strutil-checks() : div list<result>
  [
    check("kebab splits words", str-kebab("Hello World") == "hello-world"),
    check("kebab collapses punctuation", str-kebab("Hello, World!") == "hello-world"),
    check("kebab splits camel case", str-kebab("helloWorld") == "hello-world"),
    check("kebab keeps digits", str-kebab("koka 2") == "koka-2"),
    check("snake uses underscores", str-snake("MyCoolApp") == "my_cool_app"),
    check("words drops empty fields", str-words("  a  b  ") == [ "a", "b" ]),
    check("split on a character", str-split-char("a/b/c", '/') == [ "a", "b", "c" ]),
    check("split drops empty fields", str-split-char("a//b", '/') == [ "a", "b" ]),
    check("lines drops the trailing empty field", str-lines("a\nb\n") == [ "a", "b" ]),
    check("lines keeps interior blanks", str-lines("a\n\nb\n") == [ "a", "", "b" ]),

    check("a valid name is accepted", str-valid-name("my-app")),
    check("a name with uppercase is rejected", !str-valid-name("My-App")),
    check("a name with a space is rejected", !str-valid-name("my app")),
    check("a name with a leading dash is rejected", !str-valid-name("-app")),
    check("a name with a trailing dash is rejected", !str-valid-name("app-")),
    check("a name with doubled dashes is rejected", !str-valid-name("my--app")),
    check("an empty name is rejected", !str-valid-name("")),
    check("sanitize produces a valid name", str-valid-name(str-sanitize-name("My Cool App!!"))),
    check("sanitize keeps a good name", str-sanitize-name("my-app") == "my-app"),
    check("sanitize never returns empty", str-sanitize-name("!!!").is-notempty),

    check("distance is zero for equal words", str-distance("abc", "abc") == 0),
    check("distance counts a substitution", str-distance("--nme", "--name") == 1),
    check("distance counts an insertion", str-distance("sittng", "sitting") == 1),
    check("distance is symmetric",
          str-distance("kitten", "sitting") == str-distance("sitting", "kitten")),
    check("distance handles an empty left", str-distance("", "abc") == 3),
    check("distance handles an empty right", str-distance("abc", "") == 3),
    check("closest suggests the near name", str-closest("--nme", [ "--name", "--yes" ]) == Just("--name")),
    check("closest gives up on nonsense", str-closest("zzzzzz", [ "init", "build" ]) == Nothing),

    check("starts with", str-starts-with("nixpkgs.url", "nixpkgs.")),
    check("ends with", str-ends-with("a.nix", ".nix")),
    check("ends with handles a short string", !str-ends-with("nix", "a.nix")),
    check("drop drops a prefix", str-drop("--name", 2) == "name"),
    check("before splits at the separator", str-before("a.b.c", '.') == Just("a")),
    check("before is nothing when absent", str-before("abc", '.') == Nothing),
    check("quoted reads a run", str-quoted("x.url = \"ref\";", '"') == Just("ref")),
    check("quoted is nothing when unquoted", str-quoted("x = 1;", '"') == Nothing),

    check("shell quoting leaves safe words alone", str-shquote("plain") == "plain"),
    check("shell quoting protects a space", str-shquote("a b") == "'a b'"),
    check("shell quoting protects a quote", str-shquote("it's") == "'it'\\''s'"),
    check("shell join keeps arguments apart", str-shjoin([ "a", "b c" ]) == "a 'b c'"),
    check("last of a list", last([ 1, 2, 3 ]).default(0) == 3),
    check("last of an empty list", last([] : list<int>).default(7) == 7),
    check("filter-map drops the Nothings", filter-map([ Just(1), Nothing, Just(3) ], fn(x) x) == [ 1, 3 ]),
  ]

// ---------- args ----------

val demo-args : list<argdef> = [
  arg-switch("yes", "y", "assume yes"),
  arg-switch("git", "", "make a repository"),
  arg-opt("name", "n", "NAME", "the name"),
  arg-opt("template", "t", "KIND", "the template"),
]

// `parse-args` reaches for a suggestion when it meets an unknown option, so
// this group is `div` like the string checks rather than a plain value.
fun arg-checks() : div list<result>
  [
    check("a long switch is seen", parse-args(demo-args, [ "--yes" ]).has("yes")),
    check("a short switch is seen", parse-args(demo-args, [ "-y" ]).has("yes")),
    check("an option takes the next word", parse-args(demo-args, [ "--name", "foo" ]).value("name") == Just("foo")),
    check("an option takes an attached value", parse-args(demo-args, [ "--name=foo" ]).value("name") == Just("foo")),
    check("a short option takes the next word", parse-args(demo-args, [ "-n", "foo" ]).value("name") == Just("foo")),
    check("a short option takes an attached value", parse-args(demo-args, [ "-nfoo" ]).value("name") == Just("foo")),
    check("a short option accepts =value", parse-args(demo-args, [ "-t=lib" ]).value("template") == Just("lib")),
    check("--no- turns a switch off", flag-on(parse-args(demo-args, [ "--no-git" ]), "git", True) == False),
    check("a switch keeps its default when absent", flag-on(parse-args(demo-args, []), "git", True) == True),
    check("positionals are collected", parse-args(demo-args, [ "a", "b" ]).positional == [ "a", "b" ]),
    check("-- ends option parsing", parse-args(demo-args, [ "--", "-y" ]).passthru == [ "-y" ]),
    check("a word after -- is not a positional", parse-args(demo-args, [ "--", "x" ]).positional == []),
    check("an unknown long option is an error", parse-args(demo-args, [ "--nope" ]).errors != []),
    check("a missing value is an error", parse-args(demo-args, [ "-n" ]).errors != []),
    check("a misspelling is suggested", parse-args(demo-args, [ "--nme" ]).errors.join("").contains("--name")),
    check("usage lists every option", usage-text(demo-args).contains("--template=KIND")),
    check("set-opt replaces a value",
          set-opt(parse-args(demo-args, [ "--name", "a" ]), "name", Just("b")).value("name") == Just("b")),
    check("set-opt adds a value that was absent",
          set-opt(parse-args(demo-args, []), "name", Just("b")).value("name") == Just("b")),
    check("set-opt with nothing removes it",
          set-opt(parse-args(demo-args, [ "--name", "a" ]), "name", Nothing).value("name") == Nothing),
  ]

// ---------- prompts ----------

// The classification a yes/no question turns on. It is worth pinning down: an
// earlier version tested the *opposite* and seeded a fresh `var` with the
// empty string, so the question settled itself before it was ever asked and
// every confirmation was silently skipped.
val term-checks : list<result> = [
  check("yes settles", prompt-settles("y")),
  check("the long form of yes settles", prompt-settles("yes")),
  check("no settles", prompt-settles("n")),
  check("the long form of no settles", prompt-settles("no")),
  check("an empty line settles on the default", prompt-settles("")),
  check("nonsense does not settle", !prompt-settles("maybe")),
  check("a near miss does not settle", !prompt-settles("yep")),
  check("whitespace does not settle", !prompt-settles("  ")),
]

// ---------- registry ----------

val nel : (string, string, string, string) = ("nel-kk", "github:LitFill/nel-kk", "nonempty", "kokaLibraries")
// A ref the table does not know resolves to the `packages` shape, under an
// input named after the last segment of the ref.
val other : (string, string, string, string) = ("r", "github:o/r", "default", "packages")

fun registry-checks() : div list<result>
  [
    check("a short name resolves from the table", resolve("nel-kk", Nothing, Nothing) == nel),
    check("a full ref is left alone", resolve("github:o/r", Nothing, Nothing) == other),
    check("a bare name becomes a github ref", resolve("o/r", Nothing, Nothing) == other),
    check("--attr overrides the attribute", resolve("nel-kk", Just("elsewhere"), Nothing).thd == "elsewhere"),
    check("--library switches to kokaLibraries",
          resolve("nel-kk", Nothing, Just("lib")) == ("nel-kk", "github:LitFill/nel-kk", "lib", "kokaLibraries")),
    check("--library names the attribute", resolve("github:o/r", Nothing, Just("lib")).thd == "lib"),
    check("the input name is the last path segment", nix-input("github:LitFill/nel-kk") == "nel-kk"),
    check("an input name is normalised", nix-input("github:o/Some_Repo") == "some-repo"),
    check("a packages entry reaches share/koka", entry-for("x", "packages", "default").contains("/share/koka/")),
    check("a packages entry is per system",
          entry-for("x", "packages", "default").contains("pkgs.stdenv.hostPlatform.system")),
    check("a kokaLibraries entry is per system",
          entry-for("x", "kokaLibraries", "m").contains("kokaLibraries.")),
    check("a kokaLibraries entry ends at includePath",
          entry-for("x", "kokaLibraries", "m").contains(".includePath")),
  ]

// ---------- templates ----------

val demo : settings = Settings("demo-app", "A demo", "0.1.0", "Nobody", "MIT", "2026", "bin")
val demo-lib : settings = Settings("demo-lib", "A library", "0.1.0", "Nobody", "MIT", "2026", "lib")
val demo-test : settings = Settings("demo-test", "A test", "0.1.0", "Nobody", "MIT", "2026", "test")

fun template-checks() : div list<result>
  [
    check("the name reaches the flake", render-flake(demo).contains("pname = \"demo-app\"")),
    check("the description reaches the flake", render-flake(demo).contains("A demo")),
    check("the version reaches the flake", render-flake(demo).contains("version = \"0.1.0\"")),
    check("nix interpolation survives rendering", render-flake(demo).contains("$" ++ "{system}")),
    check("no nix placeholder survives rendering", render-flake(demo).contains("#{") == False),
    check("no file placeholder survives rendering", render-flake(demo).contains("{{") == False),
    check("the inputs markers are present", render-flake(demo).contains(inputs-start)),
    check("the libs markers are present", render-flake(demo).contains(libs-start)),
    check("the dev shell writes koka.json", render-flake(demo).contains("koka.json")),
    check("a lib template publishes kokaLibraries", render-flake(demo-lib).contains("kokaLibraries")),
    check("a test template runs its tests", render-flake(demo-test).contains("test/test.kk")),
    check("the bin template writes five files", template-files(demo).length == 5),
    check("the lib template writes six files", template-files(demo-lib).length == 6),
    check("the test template writes six files", template-files(demo-test).length == 6),
    check("the lib template puts the module in src/",
          template-files(demo-lib).any fn(f) f.path == "src/demo_lib.kk"),
    check("the test template writes a test module",
          template-files(demo-test).any fn(f) f.path == "test/test.kk"),
  ]

// ---------- the flake model ----------
//
// These run against the file the template really produces, so a round trip
// that quietly dropped a line would fail here rather than in someone's project.

fun parse-or-die(text : string) : kflake
  match parse-flake(text)
    Nothing -> impossible("a generated flake did not parse:\n" ++ text)
    Just(f) -> f

val fresh : kflake = parse-or-die(render-flake(demo))

fun with-dep() : div kflake
  parse-or-die(flake-add(fresh, "nel-kk", "github:LitFill/nel-kk",
                         entry-for("nel-kk", "kokaLibraries", "nonempty")))

fun after-remove-text() : div string
  flake-remove(with-dep(), "nel-kk")

fun after-remove() : div kflake
  parse-or-die(after-remove-text())

fun with-two-text() : div string
  flake-add(with-dep(), "html", "github:koka-community/html",
            entry-for("html", "packages", "default"))

fun with-two() : div kflake
  parse-or-die(with-two-text())

// A flake the user has touched by hand: blank lines above and below that the
// template never emits. `str-lines` feeds the write path, so anything it trims
// is dropped from the file the first time `koki add` or `koki remove` runs.
fun hand-edited() : string
  "\n" ++ render-flake(demo) ++ "\n"

fun hand-edited-round-trip() : div string
  val added = flake-add(parse-or-die(hand-edited()), "nel-kk",
                        "github:LitFill/nel-kk",
                        entry-for("nel-kk", "kokaLibraries", "nonempty"))
  flake-remove(parse-or-die(added), "nel-kk")

fun has-input(f : kflake, want : string) : div bool
  f.flake-input-refs.any fn(r) r.name == want

fun model-checks() : div list<result>
  [
    check("a fresh flake parses", parse-flake(render-flake(demo)).is-just),
    check("a fresh flake has no dependencies", fresh.flake-deps.is-empty),
    check("nixpkgs is read as an input", has-input(fresh, "nixpkgs")),
    check("adding a dependency records it", with-dep().flake-deps.length == 1),
    check("the recorded dependency keeps its ref",
          with-dep().flake-deps.any(fn(d) d.source == "github:LitFill/nel-kk")),
    check("the recorded dependency keeps its expression",
          with-dep().flake-deps.any(fn(d) d.entry.contains("kokaLibraries"))),
    check("a dependency can be found by name", with-dep().flake-has("nel-kk")),
    check("removing leaves no dependency", after-remove().flake-deps.is-empty),
    check("removing drops the input it added", has-input(after-remove(), "nel-kk") == False),
    check("removing keeps the pre-existing inputs", has-input(after-remove(), "nixpkgs")),
    check("removing keeps the file valid", parse-flake(after-remove-text()).is-just),
    check("a round trip leaves the rest of the file alone",
          after-remove-text().contains("mainProgram = \"demo-app\"")),
    check("a round trip restores the file exactly", after-remove-text() == render-flake(demo)),
    check("a hand-edited flake round trips exactly",
          hand-edited-round-trip() == hand-edited()),
    check("a second dependency is added too", with-two().flake-deps.length == 2),
    check("the second dependency has its own input", with-two-text().contains("github:koka-community/html")),
    check("a packages-style entry is recognised as a dependency",
          with-two().flake-deps.any(fn(d) d.input-name == "html")),
    check("both dependencies survive together",
          with-two().flake-deps.length == 2 && with-two-text().contains("kokaLibraries")),
  ]

// ---------- runner ----------

fun main() : io ()
  val rs = strutil-checks() ++ arg-checks() ++ term-checks ++ registry-checks()
             ++ template-checks() ++ model-checks()
  rs.foreach fn(r) {
    ((if r.ok then "ok    " else "FAIL  ") ++ r.name).println
  }
  val bad = count-failed(rs)
  val total = rs.length
  "".println
  ((total - bad).show ++ "/" ++ total.show ++ " passed").println
  if bad > 0 then exit-now(1)
