/* The test suite for koki's own logic.
 *
 * Koka has no test runner, so this is a plain program: it runs a list of
 * named checks, prints one line each, and exits non-zero if any failed. The
 * `checks` derivation in flake.nix builds and runs it, so `koki check` fails
 * when this fails.
 */

module test/run

import std/os/dir
import std/os/file
import std/os/path
import std/os/process
import util

import src/args
import src/cmd-nix
import src/cmd-project
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
    check("distance counts two edits", str-distance("kitten", "sitting") == 3),
    check("distance counts a transposition as two", str-distance("biuld", "build") == 2),
    check("distance is not fooled by a shared first letter",
          str-distance("biuld", "add") == 4),
    check("closest prefers the real word over a shorter one",
          str-closest("biuld", [ "init", "new", "add", "remove", "build" ]) == Just("build")),
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

// ---------- colour ----------

// The precedence is a decision table, not a ladder of side effects: the
// environment answer is pure in its arguments, so every branch is pinned.
fun color-checks() : io list<result>
  [
    check("KOKI_COLOR=never wins over a terminal",
          !color-from-env(Just("never"), False, Just("1"), Nothing, True)),
    check("KOKI_COLOR=0 is off",
          !color-from-env(Just("0"), False, Nothing, Nothing, True)),
    check("KOKI_COLOR=always wins over NO_COLOR",
          color-from-env(Just("always"), True, Nothing, Nothing, False)),
    check("KOKI_COLOR=1 is on",
          color-from-env(Just("1"), False, Nothing, Nothing, False)),
    check("NO_COLOR beats CLICOLOR_FORCE",
          !color-from-env(Nothing, True, Just("1"), Nothing, True)),
    check("CLICOLOR_FORCE beats an absent terminal",
          color-from-env(Nothing, False, Just("1"), Nothing, False)),
    check("CLICOLOR_FORCE=0 does not force colour",
          !color-from-env(Nothing, False, Just("0"), Nothing, False)),
    check("CLICOLOR_FORCE=1 does",
          color-from-env(Nothing, False, Just("1"), Nothing, False)),
    check("TERM=dumb beats a terminal",
          !color-from-env(Nothing, False, Nothing, Just("dumb"), True)),
    check("a terminal decides when nothing else does",
          color-from-env(Nothing, False, Nothing, Nothing, True)),
    check("a pipe is colourless",
          !color-from-env(Nothing, False, Nothing, Nothing, False)),
    check("the Never choice is off", resolve-color(Never) == False),
    check("the Always choice is on", resolve-color(Always) == True),
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
    // Pinned as whole expressions rather than substrings: these strings are
    // written into the user's flake.nix, and a mangled interpolation — a `$`
    // where a `/` belongs, a stray `}` — is still "contains /share/koka/".
    check("a packages entry is exact",
          entry-for("x", "packages", "default")
            == "\"" ++ nix-dollar ++ "{self.inputs.x.packages."
               ++ nix-dollar ++ "{pkgs.stdenv.hostPlatform.system}.default}"
               ++ "/share/koka/" ++ nix-dollar ++ "{pkgs.koka.version}\""),
    check("a kokaLibraries entry is exact",
          entry-for("x", "kokaLibraries", "m")
            == "self.inputs.x.kokaLibraries." ++ nix-dollar
               ++ "{pkgs.stdenv.hostPlatform.system}.m.includePath"),
  ]

// ---------- templates ----------

val demo : settings = Settings("demo-app", "A demo", "0.2.0", "Nobody", "MIT", "2026", "bin")
val demo-lib : settings = Settings("demo-lib", "A library", "0.2.0", "Nobody", "MIT", "2026", "lib")
val demo-test : settings = Settings("demo-test", "A test", "0.2.0", "Nobody", "MIT", "2026", "test")

fun template-checks() : div list<result>
  [
    check("the name reaches the flake", render-flake(demo).contains("pname = \"demo-app\"")),
    check("the description reaches the flake", render-flake(demo).contains("A demo")),
    check("the version reaches the flake", render-flake(demo).contains("version = \"0.2.0\"")),
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
    // The generated flake uses the same small helper style as koki's own
    // flake: `inherit`, pipelines, and one `let` around each output.
    check("the flake uses inherit helpers",
          render-flake(demo).contains("inherit (nixpkgs.lib) genAttrs;")
            && render-flake(demo).contains("inherit (builtins) concatStringsSep elem;")),
    check("the flake avoids experimental pipe operators",
          !render-flake(demo).contains("|>")
            && !render-flake(demo).contains("<|")
            && render-flake(demo).contains("concatStringsSep")),
    check("the package uses mkDerivation from a let",
          render-flake(demo).contains("let\n          inherit (pkgs.stdenv) mkDerivation;")),
    check("the app has metadata",
          render-flake(demo).contains("meta = {")
            && render-flake(demo).contains("mainProgram = \"demo-app\";")),
    check("the source filter is shared",
          render-flake(demo).contains("projectSrc =")
            && render-flake(demo).contains("src = projectSrc pkgs;")),
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

// A flake that ends without a newline. `str-lines` drops the trailing empty
// field, so joining without one reproduces the file minus its final newline.
fun no-final-newline() : string
  render-flake(demo).str-lines.join("\n")

fun no-final-newline-round-trip() : div string
  val added = flake-add(parse-or-die(no-final-newline()), "nel-kk",
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
    // The line that actually lands in flake.nix, whole, as written.
    check("the written packages entry is exact",
          with-two-text().contains(
            "        \"" ++ nix-dollar ++ "{self.inputs.html.packages."
              ++ nix-dollar ++ "{pkgs.stdenv.hostPlatform.system}.default}"
              ++ "/share/koka/" ++ nix-dollar ++ "{pkgs.koka.version}\"")),
    check("both dependencies survive together",
          with-two().flake-deps.length == 2 && with-two-text().contains("kokaLibraries")),
    check("a flake that ends without a newline is read as such",
          !parse-or-die(no-final-newline()).newline),
    check("a rewrite keeps a missing final newline",
          no-final-newline-round-trip() == no-final-newline()),
    check("a normal flake keeps its final newline", fresh.newline),
  ]

// ---------- the managed regions ----------
//
// The libs region is koki's, not a scratch pad: a line in it that is not an
// entry is a dependency `remove` would drop the input for and leave behind.
// The input scan is scoped to `inputs = { ... }`, because the shape it looks
// for also occurs outside that block by coincidence.

fun with-libs-line(text : string, line : string) : string
  text.replace-all(libs-start, libs-start ++ "\n        " ++ line)

val hand-line : string = "builtins.getFlake \"./extra\""

fun region-checks() : div list<result>
  val hand      = parse-or-die(with-libs-line(render-flake(demo), hand-line))
  val commented = parse-or-die(with-libs-line(render-flake(demo), "# a note koki did not write"))
  val sneaky    = parse-or-die(render-flake(demo).replace-all(
    "  description = \"A demo\";",
    "  description = \"A demo\";\n  meta.name = \"not-an-input\";"))
  [
    check("a generated libs region is all entries",
          flake-unreadable(fresh).is-empty),
    check("a comment in the libs region is readable",
          flake-unreadable(commented).is-empty),
    check("a hand-written line is reported",
          flake-unreadable(hand) == [ "        " ++ hand-line ]),
    check("a hand-written line is not a dependency",
          hand.flake-deps.is-empty),
    check("an assignment outside the inputs block is not an input",
          !has-input(sneaky, "meta")),
    check("nixpkgs is still read from the inputs block",
          has-input(fresh, "nixpkgs")),
  ]

// ---------- dependency edits ----------
//
// `koki add` derives an input name from whatever spelling it is given, so the
// name a dependency is filed under is not the name the user typed. Removal has
// to land on that same name, or a dependency added as `LitFill/nel-kk` cannot
// be removed by the name it was added with. Both directions go through
// `apply-edits`, so both are checked here.

// The edit `koki remove <name>` would make for one spelling of a dependency.
fun remove-edit(f : kflake, name : string) : div edit
  Edit(name, remove-input(f, name), "", "")

val added-edit : edit =
  Edit("nel-kk", "nel-kk", "github:LitFill/nel-kk",
       entry-for("nel-kk", "kokaLibraries", "nonempty"))

fun edit-checks() : io list<result>
  val base     = render-flake(demo)
  val added    = flake-add(parse-or-die(base), "nel-kk", "github:LitFill/nel-kk",
                           entry-for("nel-kk", "packages", "default"))
  val path-text = flake-add(parse-or-die(base), "dep", "path:../dep",
                            entry-for("dep", "packages", "default"))
  val path-dep  = parse-or-die(path-text)
  val applied  = apply-edits(base, [ added-edit ], Adding, [], [])
  val added-f  = parse-or-die(added)
  [
    check("an addition is applied",
          applied.snd == [ "nel-kk" ] && applied.thd.is-empty),
    check("an addition writes a dependency",
          parse-or-die(applied.fst).flake-has("nel-kk")),
    check("adding the same dependency twice skips it",
          apply-edits(applied.fst, [ added-edit ], Adding, [], []).thd == [ "nel-kk" ]),
    check("a dependency added by full ref is removable by full ref",
          apply-edits(added, [ remove-edit(added-f, "LitFill/nel-kk") ], Removing, [], []).snd
            == [ "LitFill/nel-kk" ]),
    check("a dependency added by full ref is removable by bare name",
          apply-edits(added, [ remove-edit(added-f, "nel-kk") ], Removing, [], []).snd
            == [ "nel-kk" ]),
    check("removal by full ref restores the file exactly",
          apply-edits(added, [ remove-edit(added-f, "LitFill/nel-kk") ], Removing, [], []).fst
            == base),
    check("a dependency that is not there is reported missing",
          apply-edits(added, [ remove-edit(added-f, "nope") ], Removing, [], []).thd == [ "nope" ]),
    check("a path dependency is removable by the name info shows",
          remove-input(path-dep, "dep") == "dep"),
    check("a path dependency can be removed by that name",
          apply-edits(path-text, [ remove-edit(path-dep, "dep") ], Removing, [], []).snd
            == [ "dep" ]),
  ]

// ---------- the include path ----------
//
// `koki repl` turns the directories the dev shell recorded in `koka.json`
// into the `--include` flags `koka -p` needs. A path mangled on the way
// through is a module the REPL quietly cannot see, so these pin the exact
// strings and not only how many there are.

// The `koka.json` the dev shell's hook writes, in the shape it writes it.
fun kokajson(dirs : list<string>) : string
  "{\"include_dirs\":[" ++ dirs.map(fn(d) "\"" ++ d ++ "\"").join(",") ++ "]}"

// A store path with the shapes that a naive parse would damage: dashes,
// dots, slashes and a version that looks like a field separator.
val store-dir : string = "/nix/store/3k4l-my.lib-0.1.0/share/koka/v3.2.9"

fun repl-checks() : div list<result>
  [
    check("a project with no dependencies has no include path",
          include-dirs(kokajson([])) == []),
    check("no include path means no compiler flags",
          include-args(kokajson([])) == []),
    check("one dependency is read back",
          include-dirs(kokajson([ store-dir ])) == [ store-dir ]),
    check("several dependencies keep their order",
          include-dirs(kokajson([ store-dir, "/nix/store/other-1.0" ]))
            == [ store-dir, "/nix/store/other-1.0" ]),
    check("the flag is the one the build phase uses",
          include-args(kokajson([ store-dir ])) == [ "--include=" ++ store-dir ]),
    check("each dependency gets its own flag",
          include-args(kokajson([ "/a", "/b" ])) == [ "--include=/a", "--include=/b" ]),
    check("a file with no include_dirs yields nothing",
          include-dirs("{}") == []),
    check("a file that is not the expected shape yields nothing",
          include-dirs("not json at all") == []),
    check("an unterminated list yields what is there",
          include-dirs("{\"include_dirs\":[\"/a\",\"/b\"") == [ "/a", "/b" ]),
    check("a hand-unquoted field is still usable",
          include-dirs("{\"include_dirs\":[/a]}") == [ "/a" ]),
    check("an empty entry does not reset the module path",
          include-args("{\"include_dirs\":[\"\"]}") == []),
    check("an empty entry does not lose the directories around it",
          include-args("{\"include_dirs\":[\"\",\"" ++ store-dir ++ "\"]}")
            == [ "--include=" ++ store-dir ]),
  ]

// ---------- dispatch ----------
//
// Everything above tests functions. These run the built binary, because the
// argument-to-command mapping, the help text and the error messages only
// exist as a program: a `set-opt` that lost the project name would still pass
// every check that only looked at `parse-args`. The `checks` derivation
// builds `./koki` from the same source before running this suite; locally,
// `koka -o koki main.kk` first.

// Run `koki <args>` with `dir` as the working directory, returning the exit
// status and everything it printed. `args` is a shell fragment rather than a
// quoted string, so a caller can pass an argument that needs quoting.
fun koki-in(bin : string, dir : string, args : string, env : string = "") : io (int, string)
  // The log lives beside `dir`, not inside it: a directory koki is asked to
  // initialise must still look empty when koki looks at it.
  val log = dirname(dir.path) ++ "/.koki-out-" ++ basename(dir.path)
  val rc  = run-system("cd %1 && %2 %3 %4 > %5 2>&1"
                      %^[str-shquote(dir), env, str-shquote(bin), args, str-shquote(log)])
  val out = match try fn() { log.path.read-text-file }
    Ok(s)    -> s
    Error(_) -> ""
  (rc, out)

// A directory of the suite's own, so no check can leave anything behind.
fun scratch-dir() : io string
  match run-system-read("mktemp -d")
    Ok(s)    -> s.trim
    Error(_) -> "."

fun project-file(dir : string, name : string) : io bool
  is-file((dir ++ "/" ++ name).path)

fun file-has(dir : string, name : string, needle : string) : io bool
  match try fn() { (dir ++ "/" ++ name).path.read-text-file }
    Ok(s)    -> s.contains(needle)
    Error(_) -> False

fun dispatch-checks() : io list<result>
  val bin = cwd().string ++ "/koki"

  // Help, version and dispatch. None of these touch the filesystem.
  val d0 = scratch-dir()
  val usage     = koki-in(bin, d0, "")
  val version   = koki-in(bin, d0, "--version")
  val help      = koki-in(bin, d0, "help")
  val help-add  = koki-in(bin, d0, "help add")
  val help-help = koki-in(bin, d0, "help help")
  val typo      = koki-in(bin, d0, "biuld")
  val bad-opt   = koki-in(bin, d0, "init --nme x")

  // Errors that need no project.
  val new-noname = koki-in(bin, d0, "new")
  val add-none   = koki-in(bin, d0, "add")
  val rm-none    = koki-in(bin, d0, "remove")

  // A project, created and read back through the commands that read one.
  val d1 = scratch-dir()
  val new-bin = koki-in(bin, d1, "new --yes --no-git demo")
  val info    = koki-in(bin, d1 ++ "/demo", "info")
  val doctor  = koki-in(bin, d1 ++ "/demo", "doctor")
  val quiet-info   = koki-in(bin, d1 ++ "/demo", "--quiet info")
  val verbose-info = koki-in(bin, d1 ++ "/demo", "info -v")
  val rm-missing   = koki-in(bin, d1 ++ "/demo", "remove --yes nope")
  val typo-add     = koki-in(bin, d1 ++ "/demo", "add --dry-run nel-k")

  // The library template.
  val d2 = scratch-dir()
  val new-lib = koki-in(bin, d2, "new --yes --no-git -t lib my-lib")

  // A name no project can have, a template that does not exist, a directory
  // that already holds something, and a run that writes nothing.
  val d3 = scratch-dir()
  val bad-name = koki-in(bin, d3, "new --yes --no-git \"My App\"")
  val bad-kind = koki-in(bin, d3, "new --yes --no-git -t nope thing")
  val d4 = scratch-dir()
  match try fn() { (d4 ++ "/keep").path.write-text-file("keep") }
    Ok(_)    -> ()
    Error(_) -> ()
  val non-empty = koki-in(bin, d4, "init --yes --no-git")
  val d5 = scratch-dir()
  val dry = koki-in(bin, d5, "init --yes --no-git --dry-run app")

  // A libs region koki cannot read is refused rather than edited around.
  val d6 = scratch-dir()
  val new-hand = koki-in(bin, d6, "new --yes --no-git hand")
  match try fn() {
    val p = (d6 ++ "/hand/flake.nix").path
    p.write-text-file(
      p.read-text-file.replace-all(libs-start, libs-start ++ "\n        ./extra"))
  }
    Ok(_)    -> ()
    Error(_) -> ()
  val remove-hand = koki-in(bin, d6 ++ "/hand", "remove --yes nel-kk")
  val add-hand    = koki-in(bin, d6 ++ "/hand", "add --yes nel-kk")

  // With no git on the PATH the repository cannot be made, and the footer
  // must not offer a commit there is nothing to commit to.
  val d7 = scratch-dir()
  val no-git = koki-in(bin, d7, "new --yes demo", "PATH=")

  // A project created in a directory of its own takes that directory's name.
  val d8 = scratch-dir()
  match try fn() { (d8 ++ "/nameit").path.ensure-dir }
    Ok(_)    -> ()
    Error(_) -> ()
  val init-named = koki-in(bin, d8 ++ "/nameit", "init --yes --no-git")

  // Doctor has somewhere to stand and no project to stand in.
  val doctor-none = koki-in(bin, d0, "doctor")

  [
    check("no arguments prints the overview",
          usage.fst == 0 && usage.snd.contains("Usage:") && usage.snd.contains("doctor")),
    check("--version prints the name",
          version.fst == 0 && str-starts-with(version.snd, "koki ")),
    check("help prints the overview",
          help.fst == 0 && help.snd.contains("Usage:")),
    check("help prints a command's options",
          help-add.fst == 0
            && help-add.snd.contains("--attr")
            && help-add.snd.contains("--library")),
    check("help help prints its own help",
          help-help.fst == 0 && help-help.snd.contains("koki help [COMMAND]")),
    check("a typo is named and the nearest command suggested",
          typo.fst == 2 && typo.snd.contains("no such command") && typo.snd.contains("build")),
    check("a misspelt option is suggested",
          bad-opt.fst == 2 && bad-opt.snd.contains("--name")),
    check("new without a name is rejected",
          new-noname.fst == 2 && new-noname.snd.contains("needs a name")),
    check("add without a dependency is rejected",
          add-none.fst == 2 && add-none.snd.contains("needs at least one dependency")),
    check("remove without a dependency is rejected",
          rm-none.fst == 2 && rm-none.snd.contains("needs at least one dependency")),
    check("new writes a project",
          new-bin.fst == 0 && project-file(d1, "demo/flake.nix")),
    check("the new project's flake names it",
          file-has(d1, "demo/flake.nix", "pname = \"demo\"")),
    check("new writes the program module",
          project-file(d1, "demo/main.kk")),
    check("info describes the project",
          info.fst == 0 && info.snd.contains("koka project") && info.snd.contains("demo")),
    check("doctor reads the marker regions back",
          doctor.snd.contains("flake.nix has the koki marker regions")),
    check("the library template writes its module",
          new-lib.fst == 0
            && project-file(d2, "my-lib/src/my_lib.kk")
            && project-file(d2, "my-lib/example.kk")),
    check("an invalid project name is rejected",
          bad-name.fst == 2 && !project-file(d3, "My App/flake.nix")),
    check("an unknown template is rejected",
          bad-kind.fst == 2 && bad-kind.snd.contains("unknown template")),
    check("init refuses a non-empty directory",
          non-empty.fst == 1 && non-empty.snd.contains("is not empty")),
    check("a dry run writes nothing",
          dry.fst == 0 && !project-file(d5, "app/flake.nix")),
    check("doctor outside a project says so",
          doctor-none.snd.contains("not inside a koki project")),
    check("remove refuses a libs region it cannot read",
          remove-hand.fst == 1 && remove-hand.snd.contains("libs region")),
    check("add refuses a libs region it cannot read",
          add-hand.fst == 1 && add-hand.snd.contains("libs region")),
    check("the refused edit leaves the flake alone",
          file-has(d6, "hand/flake.nix", "./extra")),
    check("a missing git is reported and no commit is offered",
          no-git.fst == 0
            && no-git.snd.contains("could not run `git init`")
            && !no-git.snd.contains("commit it")),
    check("the project is created even without git",
          project-file(d7, "demo/flake.nix")),
    check("a global flag before the command still runs it",
          quiet-info.fst == 0 && quiet-info.snd.contains("koka project")),
    check("--verbose echoes the nix command",
          verbose-info.snd.contains("nix eval")),
    check("a removal that finds nothing fails",
          rm-missing.fst == 1 && rm-missing.snd.contains("nothing changed")),
    check("a typo'd short name is suggested",
          typo-add.fst == 0 && typo-add.snd.contains("did you mean `nel-kk`")),
    check("init names the project after its directory",
          init-named.fst == 0
            && file-has(d8, "nameit/flake.nix", "pname = \"nameit\"")),
  ]

// ---------- runner ----------

fun main() : io ()
  val rs = strutil-checks() ++ arg-checks() ++ term-checks ++ color-checks()
             ++ registry-checks() ++ template-checks() ++ model-checks() ++ region-checks()
             ++ edit-checks() ++ repl-checks()
             ++ dispatch-checks()
  rs.foreach fn(r) {
    ((if r.ok then "ok    " else "FAIL  ") ++ r.name).println
  }
  val bad = count-failed(rs)
  val total = rs.length
  "".println
  ((total - bad).show ++ "/" ++ total.show ++ " passed").println
  if bad > 0 then exit-now(1)
