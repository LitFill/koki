/* Project templates.
 *
 * A template body is an ordinary Koka string with two kinds of placeholder:
 *
 *   `{{name}}` and friends are filled in from the settings
 */

module src/templates

import util

import src/strutil

// One file to write into a fresh project.
pub struct newfile
  path : string
  body : string

// Everything the templates interpolate.
pub struct settings
  name    : string = ""
  desc    : string = ""
  version : string = ""
  author  : string = ""
  license : string = ""
  year    : string = ""
  kind    : string = ""    // "bin", "lib" or "test"

// ---------- rendering ----------

fun remove-first-newline(s: string): string
  s.starts-with("\n").map(_.string).default(s)

fun subst(text : string, key : string, value : string) : string
  text.replace-all("{{" ++ key ++ "}}", value)

fun render(text : string, s : settings) : string
  text.subst("name",    s.name)
      .subst("module",  str-snake(s.name))
      .subst("desc",    s.desc)
      .subst("version", s.version)
      .subst("author",  s.author)
      .subst("license", s.license)
      .subst("year",    s.year)

// ---------- shared pieces ----------

val flake-preamble : string = r#"
{
  description = "{{desc}}";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # koki:inputs:start
    # koki:inputs:end
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system} system);

      # One Koka include directory per dependency. `koki add` writes the
      # lines between the markers below and `koki remove` takes them out;
      # the compiler flags and the editor include list further down are both
      # derived from them, so they cannot drift out of step with each other.
      kokaLibsFor = pkgs: [
        # koki:libs:start
        # koki:libs:end
      ];

      # `--include` flags for the compiler.
      kokaLibArgs = pkgs:
        builtins.concatStringsSep " " (map (d: "--include=${d}") (kokaLibsFor pkgs));

      # The same list as a `koka.json` `include_dirs` array, which is what
      # editors and the Koka language server read.
      kokaJson = pkgs:
        ''{"include_dirs":[${builtins.concatStringsSep "," (map (d: "\"${d}\"") (kokaLibsFor pkgs))}]}'';
    in
    {
"#.remove-first-newline

// Keep the interpreter output of generated sources out of the build.
val src-filter : string = r#"
          src = pkgs.lib.cleanSourceWith {
            src = self;
            filter = path: type:
              let base = baseNameOf (toString path);
              in !(builtins.elem base [ "result" "koka.json" ".koka" ]);
          };
"#.remove-first-newline

val gitignore : string = r#"
# Koka build output
.koka/

# Written by the dev shell on every `nix develop`
koka.json

# Nix
result
result-*

# Compiled binaries
{{name}}
test-bin
"#.remove-first-newline

val license : string = r#"
MIT License

Copyright (c) {{year}} {{author}}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"#.remove-first-newline

// ---------- per-kind templates ----------

val bin-flake : string = flake-preamble ++ r#"
      packages = forAllSystems (pkgs: system: {
        default = pkgs.stdenv.mkDerivation {
          pname = "{{name}}";
          version = "{{version}}";
"# ++ src-filter ++ r#"
          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];

          buildPhase = ''
            runHook preBuild
            koka -o {{name}} ${kokaLibArgs pkgs} main.kk
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 {{name}} $out/bin/{{name}}
            runHook postInstall
          '';

          meta = {
            description = "{{desc}}";
            mainProgram = "{{name}}";
            platforms = pkgs.lib.platforms.unix;
          };
        };
      });

      apps = forAllSystems (pkgs: system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/{{name}}";
        };
      });

      devShells = forAllSystems (pkgs: system: {
        default = pkgs.mkShell {
          packages = [ pkgs.koka ];
          shellHook = "printf '%s\\n' '${kokaJson pkgs}' > \"$PWD/koka.json\"";
        };
      });

      checks = forAllSystems (pkgs: system: {
        build = self.packages.${system}.default;
      });
    };
}
"#.remove-first-newline

val test-flake : string = flake-preamble ++ r#"
      packages = forAllSystems (pkgs: system: {
        default = pkgs.stdenv.mkDerivation {
          pname = "{{name}}";
          version = "{{version}}";
"# ++ src-filter ++ r#"
          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];

          buildPhase = ''
            runHook preBuild
            koka -o {{name}} ${kokaLibArgs pkgs} main.kk
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 {{name}} $out/bin/{{name}}
            runHook postInstall
          '';

          meta = {
            description = "{{desc}}";
            mainProgram = "{{name}}";
            platforms = pkgs.lib.platforms.unix;
          };
        };
      });

      apps = forAllSystems (pkgs: system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/{{name}}";
        };
      });

      devShells = forAllSystems (pkgs: system: {
        default = pkgs.mkShell {
          packages = [ pkgs.koka ];
          shellHook = "printf '%s\\n' '${kokaJson pkgs}' > \"$PWD/koka.json\"";
        };
      });

      # `koki check` runs these. A test that stops making the build fail is a
      # test that has stopped being a test.
      checks = forAllSystems (pkgs: system: {
        tests = pkgs.stdenv.mkDerivation {
          pname = "{{name}}-tests";
          version = "{{version}}";
          src = self;
          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];
          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            runHook preBuild
            koka ${kokaLibArgs pkgs} -o test-bin test/test.kk
            ./test-bin
            runHook postBuild
            touch $out
          '';
        };
      });
    };
}
"#.remove-first-newline

val lib-flake : string = flake-preamble ++ r#"
      packages = forAllSystems (pkgs: system: {
        default = pkgs.stdenv.mkDerivation {
          pname = "{{name}}";
          version = "{{version}}";
"# ++ src-filter ++ r#"
          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];

          buildPhase = ''
            runHook preBuild
            koka -l --output={{module}} --builddir="$PWD/.koka-build" src/{{module}}.kk
            runHook postBuild
          '';

          # A Koka library is its source: consumers resolve it with
          # `--include=<includePath>` and compile against these modules.
          installPhase = ''
            runHook preInstall
            install -Dm644 src/{{module}}.kk \
              $out/share/koka/${pkgs.koka.version}/{{module}}.kk
            runHook postInstall
          '';

          meta = {
            description = "{{desc}}";
            platforms = pkgs.lib.platforms.unix;
          };
        };
      });

      # How a consuming flake reaches this library. `koki add` writes
      # `self.inputs.<input>.kokaLibraries.<system>.{{module}}.includePath`
      # when this flake is added as a dependency.
      kokaLibraries = forAllSystems (pkgs: system: {
        {{module}} = {
          path = self.packages.${system}.default;
          includePath = "${self.packages.${system}.default}/share/koka/${pkgs.koka.version}";
          version = pkgs.koka.version;
          libVersion = self.packages.${system}.default.version;
        };
      });

      devShells = forAllSystems (pkgs: system: {
        default = pkgs.mkShell {
          packages = [ pkgs.koka ];
          shellHook = "printf '%s\\n' '${kokaJson pkgs}' > \"$PWD/koka.json\"";
        };
      });

      checks = forAllSystems (pkgs: system: {
        build = self.packages.${system}.default;
      });
    };
}
"#.remove-first-newline

val bin-main : string = r#"
module main

fun greet(who : string) : string
  "Hello, " ++ who ++ "!"

fun main()
  println(greet("{{name}}"))
"#.remove-first-newline

val test-main : string = r#"
module main

// `pub` because the test module imports it: a test that cannot reach the
// thing it is testing is not a test.
pub fun greet(who : string) : string
  "Hello, " ++ who ++ "!"

fun main()
  println(greet("{{name}}"))
"#.remove-first-newline

val test-suite : string = r#"
module test

import main

// `assert` aborts on failure, so a failing test takes the whole derivation
// with it and `nix flake check` reports it as a failed check.
fun test-greet()
  val msg = greet("world")
  assert("greet greets the world", msg == "Hello, world!")

fun main() : console int
  test-greet()
  println("1 test passed")
  0
"#.remove-first-newline

val lib-module : string = r#"
module {{module}}

// A Koka library is a set of modules that other code imports by name. Put
// the module file at the root of the include directory installed by the
// flake, and `import {{module}}` will resolve for anyone who adds this
// flake as a dependency.
pub fun greet(who : string) : string
  "Hello, " ++ who ++ ", from {{name}}"
"#.remove-first-newline

val lib-example : string = r#"
module example

// Run this from the dev shell, where the library is on the include path:
//
//     nix develop
//     koka -o example example.kk && ./example
import {{module}}

fun main()
  println({{module}}/greet("world"))
"#.remove-first-newline

fun readme-for(s : settings) : string
  if s.kind == "lib" then r#"
# {{name}}

{{desc}}

## Using it

From another Koka project:

    koki add path:{{name}}

or by hand, in that project's `flake.nix`:

    inputs.my-lib.url = "path:../{{name}}";

```nix
kokaLibsFor = pkgs: [
  self.inputs.my-lib.kokaLibraries.${pkgs.stdenv.hostPlatform.system}.{{module}}.includePath
];
```

## Layout

- `src/{{module}}.kk` — the library itself
- `example.kk` — a tiny program that imports it
- `flake.nix` — the build, and the `kokaLibraries` output other flakes use

## Commands

    koki build      # nix build
    koki check      # nix flake check
    koki dev        # nix develop
"#.remove-first-newline
  else r#"
# {{name}}

{{desc}}

## Layout

- `main.kk` — the program
- `flake.nix` — the whole build; `koki add` manages the marked regions
- `koka.json` — generated by the dev shell, not checked in

## Commands

    koki dev        # nix develop, with koka and the include path set up
    koki repl       # the Koka REPL, with the dependencies on the path
    koki run        # build and run the program
    koki build      # nix build
    koki check      # nix flake check
    koki add <dep>  # add a Koka library as a flake input
"#.remove-first-newline

// ---------- assembling ----------

// The `flake.nix` body for these settings. Exposed so the test suite can
// exercise the flake model against a file koki would really write, rather
// than against a fixture that can drift from the template.
pub fun render-flake(s : settings) : string
  match s.kind
    "lib"  -> render(lib-flake,  s)
    "test" -> render(test-flake, s)
    _      -> render(bin-flake,  s)

pub fun template-files(s : settings) : list<newfile>
  val base = [
    Newfile("flake.nix",  render-flake(s)),
    Newfile(".gitignore", render(gitignore,     s)),
    Newfile("README.md",  render(readme-for(s), s)),
    Newfile("LICENSE",    render(license,       s)),
  ]
  match s.kind
    "lib"  -> base ++ [
        Newfile("src/%1.kk"%^[str-snake(s.name)], render(lib-module, s)),
        Newfile("example.kk", render(lib-example, s)),
      ]
    "test" -> base ++ [
        Newfile("main.kk", render(test-main, s)),
        Newfile("test/test.kk", render(test-suite, s)),
      ]
    _      -> base ++ [ Newfile("main.kk", render(bin-main, s)) ]
