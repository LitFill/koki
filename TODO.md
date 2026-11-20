# TODO

Grounded in what is actually true of the code as of `0.2.0`. Each item says
what was observed, so a later reader can tell a real defect from a guess.

Priorities: **high** — wrong results, or a footgun that can cost something;
**medium** — a real limitation someone will hit; **low** — polish.

## Correctness risks

- **`entry-input` and `registry.kk` agree on `self.inputs.` only.** If the two
  ever drift, `koki add` writes a shape `koki remove` cannot read; the region
  is then refused rather than half-edited, so the drift is loud. One constant,
  used by both, would remove the possibility.
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

## UX

- **open — exit codes without a command.** `koki` with no arguments and
  `koki doctor` outside a project both print help or advice and exit 0.
  Decide whether a script should read those as failure.

## Testing gaps

- **No end-to-end test that builds a generated project.** The templates are
  verified by hand, not by CI. A check that runs `koki init -t lib`, adds it to
  a scratch project as a `path:` input and builds would close the loop.

## Code

- **`src/templates.kk` is 448 lines of `++`.** One file per template, or a
  heredoc-style helper, would make the generated flakes readable as flakes
  rather than as concatenations. The `#{` escaping in particular costs more to
  read than the Nix it produces.
- **`apply-edits` re-parses and re-splices the file once per dependency**, and
  `splice` is built from `take`/`drop`, so adding *n* dependencies is O(n²) in
  the file length. Fine at this size; worth knowing before anyone adds ten.
- **The `command` record holds a function, so calling it needs `(c.action)(p)`.**
  Correct, but surprising enough that it deserves a comment at the definition.

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
- **`koki init --force` overwrites without showing what it will change.** A
  diff before overwriting would be a safety net.
- **A `nix flake lock` failure scrolls past.** koki reports that it failed and
  suggests running it by hand, which is right, but the reason is not shown.
- **`koki info` evaluates the flake.** The version row is a `nix eval`, so the
  command is as slow as Nix and needs the inputs available; it falls back to
  `(not evaluated)` offline, and `--no-write-lock-file` keeps it from leaving a
  `flake.lock` behind.

## Packaging

- **No CI.** `checks` is wired up and green locally; nothing runs it on push.
  The other repos in this workspace use flake-utils' GitHub matrix, which is
  the obvious thing to copy.
- **No release process.** No tags, no `nix profile install` instructions
  verified against a real tag, no changelog.
