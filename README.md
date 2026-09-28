# koki

The Koka project manager.

A Koka project is a directory with a `flake.nix`. koki writes that file, keeps
its dependency list, and hands the actual building to Nix — so there is no
second manifest, no second lockfile, and nothing to fall out of step with
either.

```
$ koki new my-app
✔ created my-app (bin)

Next steps:
  1.  enter the project
      cd my-app
  2.  enter the dev shell
      koki dev
  3.  build and run it
      koki run
```

## Installing

koki is a Nix flake, so it installs the way everything else in the Koka
ecosystem does:

```console
$ nix profile install github:LitFill/koki
```

Or run it without installing:

```console
$ nix run github:LitFill/koki -- init
```

## Commands

| Command | What it does |
| --- | --- |
| `koki init [DIR]` | create a project in the current directory |
| `koki new <NAME> [DIR]` | create a project in a new directory |
| `koki add <DEP>...` | add Koka libraries as flake inputs |
| `koki remove <DEP>...` | remove dependencies `koki add` added |
| `koki build` | `nix build` |
| `koki run [ARGS...]` | build and run the program |
| `koki check` | run the flake's checks |
| `koki dev [COMMAND...]` | enter the development shell |
| `koki info` | what koki knows about this project |
| `koki doctor` | check the toolchain and the project |

`koki help <command>` prints the options for one command. `koki --version` and
`--quiet`, `--no-color`, `--color`, `--verbose` work everywhere.

## Templates

`koki init -t bin` (the default) makes an executable, `lib` makes a library
other Koka projects can depend on, and `test` is `bin` plus a test module wired
into `nix flake check`.

All three write a `flake.nix` that builds on Linux and macOS, on x86-64 and
aarch64, with a dev shell that regenerates `koka.json` so editors and the Koka
language server see the same modules the compiler will.

## Interactive

`koki init`, `koki new`, `koki add` and `koki remove` ask for what you did not
say, offering the default in brackets:

```console
$ koki new game
Project name [game]:
Template (bin, lib, test) [bin]:
Description [A Koka project]:
Author [Anonymous]:
License [MIT]:
Version [0.1.0]:
✔ created game (bin)
```

This happens only when stdin is a terminal. Piped or redirected, and on the
first run under CI, koki takes the defaults instead of blocking on a question
nobody is there to answer — and `--yes` says so explicitly. A yes/no question
re-asks rather than guessing. Every prompt flushes before it waits, so the
question is on screen before the program blocks.

## Dependencies

A Koka library is just a flake output that says where its modules live. koki
reads that, and keeps the list in the `kokaLibsFor` of the project's
`flake.nix`:

```console
$ koki add nel-kk
✔ nel-kk  github:LitFill/nel-kk
  self.inputs.nel-kk.kokaLibraries.${pkgs.stdenv.hostPlatform.system}.nonempty.includePath
✔ added 1 dependency to flake.nix
✔ flake.lock is up to date
```

Anything with a flake ref works: `koki add github:owner/repo`,
`koki add path:../my-lib`, `koki add https://host/repo`. Two flags cover the
shapes a dependency might publish:

- `--attr NAME` — the package attribute holding the library.
- `--library NAME` — the name under the dependency's `kokaLibraries`, for a
  flake that publishes one. It sets the style and the attribute together.

`koki add` and `koki remove` only ever touch lines between koki's own markers,
so anything else in the file is left exactly as it was. `koki doctor` reports a
file that has lost them rather than guessing.

## How the flake stays consistent

The compiler flags and the editor include list are both derived from the one
list of dependencies:

```nix
kokaLibsFor = pkgs: [
  # koki:libs:start
  self.inputs.nel-kk.kokaLibraries.${pkgs.stdenv.hostPlatform.system}.nonempty.includePath
  # koki:libs:end
];

kokaLibArgs = pkgs: ... map (d: "--include=${d}") (kokaLibsFor pkgs) ...;
kokaJson   = pkgs: ... the same list, as koka.json ...;
```

There is no third place to update.

## Layout

- `main.kk` — the entry point
- `src/args.kk` — the option parser
- `src/cli.kk` — dispatch, help, the command table
- `src/cmd-project.kk` — `init`, `new`, `add`, `remove`
- `src/cmd-nix.kk` — `build`, `run`, `check`, `dev`, `info`, `doctor`
- `src/cmd.kk` — the command record and the bits every command shares
- `src/project.kk` — finding a project, reading and editing `flake.nix`
- `src/registry.kk` — the short names `koki add` knows
- `src/templates.kk` — the files each template writes
- `src/strutil.kk` — string helpers
- `src/term.kk` — colour, status lines, prompts
- `test/run.kk` — the test suite

## Building

```console
$ koki dev        # a shell with koka on the PATH
$ koka -o koki main.kk
$ koki check      # builds, and runs test/run.kk
```

## License

MIT. See `LICENSE`.
