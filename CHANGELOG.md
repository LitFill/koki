# Changelog

All notable changes to koki. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version is
the `baseVersion` in `flake.nix`.

## 0.4.0 — 2026-11-23

### Added

- `koki init --merge` adds koki to a directory that already holds Koka code:
  it writes the flake and the support files and keeps the project's own
  `main.kk`, `example.kk`, `test/test.kk` and `src/<name>.kk`.

### Changed

- `koki init` in a Koka project without `--merge` or `--force` now refuses
  instead of overwriting the source files; the hint names `--merge`.

## 0.3.0 — 2026-11-21

### Added

- `koki doctor` evaluates the flake, so a broken input reference is reported
  before a build fails with a longer version of the same news.
- `--verbose` echoes the Nix commands koki runs.

### Changed

- `koki init` names the project after the directory it is created in, instead
  of always `koka-app`.
- The global flags (`--quiet`, `--color`, `--no-color`, `--verbose`) work
  before the command name as well as after it.
- Generated flakes use the same small Nix style as koki's own flake:
  `inherit`, `let`, and a shared source filter. The app output now carries
  `meta`, and the test check builds from the shared source filter. The
  generated flakes use no experimental Nix syntax.
- Errors and hints go to stderr, so `koki … 2>/dev/null` silences them.
- `koki remove` accepts the name `koki info` shows: a dependency added as
  `path:../lib` can be removed as `lib`.
- A removal that removes nothing exits 1.
- A typo'd short name suggests the closest registry entry.
- `CLICOLOR_FORCE=0` no longer forces colour.
- `koki info` no longer writes `flake.lock` as a side effect.
- `koki add` and `koki remove` refuse a `# koki:libs` region with lines they
  cannot read, and `koki doctor` reports one.

### Fixed

- `koki init` no longer stages files it did not write when the directory is
  already a repository.
- Editing a `flake.nix` that ended without a newline no longer adds one.
- `koki doctor` prints the project checks again; they were computed and then
  dropped.
- Levenshtein distances were wrong, so "did you mean" could suggest a command
  that was further away than another.

Earlier releases predate this file.