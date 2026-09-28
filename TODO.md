# TODO

Grounded in what is actually true of the code as of `0.1.0`. Each item says
what was observed, so a later reader can tell a real defect from a guess.

Priorities: **high** — wrong results, or a footgun that can cost something;
**medium** — a real limitation someone will hit; **low** — polish.

## Bugs

### high — `koki init --force` stages unrelated files

`koki init` runs `git -C <dir> add -A` after `git init`, to make the files
visible to Nix. In a directory that is *already* a repository, that stages
everything untracked, not just what koki wrote:

```console
$ git init -q . && echo secret > .env && echo notes > notes.txt
$ koki init -y --force
$ git status --short
A  .env          <- not koki's
A  notes.txt     <- not koki's
A  flake.nix
```

The next `git commit` puts those in history. Only run the `add -A` when koki
is the one that created the repository, or stage the exact paths it wrote.

### medium — hand-written dependency entries are invisible

`entry-input` recognises an entry only by looking for the literal
`self.inputs.`. A line in the libs region written any other way — a local
binding, `builtins.getFlake`, a `let`-bound path — parses as "not an entry", so
`koki info` does not list it, `koki remove` will not touch it, and `koki doctor`
reports nothing. A `# koki:libs` region the user can edit freely but koki can
only half read is worse than one it refuses to edit.

Either parse the general shape, or make the region genuinely machine-owned:
detect a non-conforming line and report it rather than ignoring it.

### medium — a `flake.nix` with a hand-added input can be miscounted

`flake-input-refs` scans *every* line of the file for `word.word = "string"`,
because `nixpkgs` sits outside the managed region. That shape occurs elsewhere
in a flake by coincidence — a `meta` field, a string in a `shellHook`. It
happens to be clean on all three templates, which is not the same as being
right. Scoping the scan to the `inputs = { ... }` block would be exact.

### low — rewriting normalises the final line ending

`koki add` rewrites the whole file from a line list, so a file that ended
without a newline gains one:

```diff
-}          <- no trailing newline
+}
```

Benign, and arguably a fix, but it is a change koki did not announce. Consider
preserving the original ending, or mentioning it in the summary line.

## Correctness risks

- **`str-after` and `entry-input` agree on `self.inputs.` only.** If the two
  ever drift, `koki add` writes a shape `koki remove` cannot find again. One
  constant, used by both, would remove the possibility.
- **`prompt-settles` treats any empty reply as "take the default".** Correct
  for a yes/no, and it is the one thing standing between a stray newline and a
  wrong answer. It is pinned by tests; keep it that way.
- **`fd-is-tty` shells out.** It runs once per process, so the cost is one
  `sh` spawn, but it means interactive detection fails on a host without a
  POSIX shell. A `isatty` extern would remove the dependency entirely.
- **`first-line-of` takes the first non-empty line** of a command's output. Any
  tool that prints a banner before its version will be misreported in
  `koki doctor`. Narrowing the expectation per tool would be sturdier.
- **Koka 3.2.9 drops updates when a closure assigning to a captured `var`
  calls another that does the same.** `src/strutil.kk` is written around this
  and says so. Do not "simplify" those accumulators into nested closures
  without re-running the tests — they pass by construction, not by luck, and
  the failure mode is a silent no-op rather than a compile error.
- **The `div` annotations are partly inference artefacts**, not statements
  about termination. Do not read them as "this may not terminate".

## Testing gaps

- **Nothing tests dispatch.** The argument-to-command mapping, the help text,
  `doctor`'s report and the `init`/`add` file writing are all untested. The
  `set-opt` bug — `koki new` skipping name validation — was found by hand and
  would have been caught by a test that runs `new` and checks the result.
  This is the largest gap in the suite.
- **No end-to-end test that builds a generated project.** The templates are
  verified by hand, not by CI. A check that runs `koki init -t lib`, adds it to
  a scratch project as a `path:` input and builds would close the loop.
- **No test for the colour decision.** `KOKI_COLOR`, `NO_COLOR`, `TERM=dumb`
  and non-tty are all reachable and none are pinned.

## Code

- **`apply-adds` and `apply-removes` in `src/cmd-project.kk` are near
  duplicates** — same shape, opposite direction. One function with a direction
  would be shorter and harder to get half-right.
- **`src/templates.kk` is 448 lines of `++`.** One file per template, or a
  heredoc-style helper, would make the generated flakes readable as flakes
  rather than as concatenations. The `#{` escaping in particular costs more to
  read than the Nix it produces.
- **`apply-adds` re-parses and re-splices the file once per dependency**, and
  `splice` is built from `take`/`drop`, so adding *n* dependencies is O(n²) in
  the file length. Fine at this size; worth knowing before anyone adds ten.
- **The `command` record holds a function, so calling it needs `(c.action)(p)`.**
  Correct, but surprising enough that it deserves a comment at the definition.
- **`koki doctor` does not check that the flake evaluates.** `nix flake metadata`
  would catch a broken input ref long before a build does.

## Features

- **Shell completions.** The command table and every option list already
  exist in one place, so generating completions for bash, zsh and fish is
  close to mechanical. Every comparable tool ships them; this is the most
  visible missing affordance.
- **`koki update`.** The lock is `flake.lock`, but refreshing it means knowing
  to type `nix flake update`. Wrapping it is small.
- **`koki info --json` and `koki doctor --json`.** Both reports are already
  structured internally (`check` records, not printed strings), so a machine
  format is cheap and makes the tool scriptable.
- **Let `koki add` accept dependencies one at a time.** It currently asks a
  single yes/no covering all of them, so `koki add a b c` is all-or-nothing.
- **Choose the nixpkgs pin and the system list at `init` time.** Both are
  hardcoded to `nixos-unstable` and four systems. `flake-utils` would also let
  the templates drop the `systems` list entirely, as the other repos here do.
- **A first dependency during `koki init`.** `npm init` offers this and it is
  the moment a new project most wants it.
- **Version drift is invisible.** The Koka compiler version comes from whatever
  nixpkgs-unstable happens to pin, so two projects built weeks apart can get
  different compilers. `koki info` could report the version the flake resolves
  and warn when it moves.

## Known limitations

- **`koki run` can only run the default app.** There is no way to pass an
  installable, so a flake with several `apps` is not reachable.
- **`kokaLibraries` is assumed to be system-scoped.** Both the `lib` template
  and the ecosystem's existing libraries are, so this is currently right — but
  a dependency publishing an unscoped `kokaLibraries.<name>` cannot be
  expressed, and `--library` has no way to say so.
- **POSIX shell throughout** — `run-system`, `test -t`, `printf` in the
  generated `shellHook`, and the quoting in `str-shquote`. Linux and macOS are
  fine; Windows is not supported, and the flake does not claim it.
- **`koki init --force` overwrites without showing what it will change.**
  Given the staging bug above, a diff before overwriting would also be a
  safety net.
- **A `nix flake lock` failure scrolls past.** koki reports that it failed and
  suggests running it by hand, which is right, but the reason is not shown.

## Packaging

- **No CI.** `checks` is wired up and green locally; nothing runs it on push.
  The other repos in this workspace use flake-utils' GitHub matrix, which is
  the obvious thing to copy.
- **`koki --version` is a literal in `src/cli.kk`** and the version is repeated
  in `flake.nix` three times — `version`, `passthru.version`, and the test
  derivation. They can drift.
- **No release process.** No tags, no `nix profile install` instructions
  verified against a real tag, no changelog.
