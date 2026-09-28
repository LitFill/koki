/* Project templates.
 *
 * A template body is an ordinary Koka string with two kinds of placeholder:
 *
 *   `{{name}}` and friends are filled in from the settings, and
 *   `#{...}` becomes `${...}` on the way out, because Koka's own string syntax
 *   would otherwise try to interpolate the Nix expression.
 */

module src/templates

import src/strutil

// One file to write into a fresh project.
pub struct newfile
  path : string
  body : string

// Everything the templates interpolate.
pub struct settings
  name    : string
  desc    : string
  version : string
  author  : string
  license : string
  year    : string
  kind    : string    // "bin", "lib" or "test"

// ---------- rendering ----------

fun subst(text : string, key : string, value : string) : string
  text.replace-all("{{" ++ key ++ "}}", value)

fun render(text : string, s : settings) : string
  val a = subst(text, "name", s.name)
  val b = subst(a, "module", str-snake(s.name))
  val c = subst(b, "desc", s.desc)
  val d = subst(c, "version", s.version)
  val e = subst(d, "author", s.author)
  val f = subst(e, "license", s.license)
  val g = subst(f, "year", s.year)
  g.replace-all("#{", "$" ++ "{")

// ---------- shared pieces ----------

// The `inputs` and `kokaLibsFor` regions are identical in every template, so
// they are written once here.
val flake-preamble : string = "{\n" ++
  "  description = \"{{desc}}\";\n" ++
  "\n" ++
  "  inputs = {\n" ++
  "    nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";\n" ++
  "\n" ++
  "    # koki:inputs:start\n" ++
  "    # koki:inputs:end\n" ++
  "  };\n" ++
  "\n" ++
  "  outputs =\n" ++
  "    { self, nixpkgs, ... }:\n" ++
  "    let\n" ++
  "      systems = [\n" ++
  "        \"x86_64-linux\"\n" ++
  "        \"aarch64-linux\"\n" ++
  "        \"x86_64-darwin\"\n" ++
  "        \"aarch64-darwin\"\n" ++
  "      ];\n" ++
  "      forAllSystems = f:\n" ++
  "        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.#{system} system);\n" ++
  "\n" ++
  "      # One Koka include directory per dependency. `koki add` writes the\n" ++
  "      # lines between the markers below and `koki remove` takes them out;\n" ++
  "      # the compiler flags and the editor include list further down are both\n" ++
  "      # derived from them, so they cannot drift out of step with each other.\n" ++
  "      kokaLibsFor = pkgs: [\n" ++
  "        # koki:libs:start\n" ++
  "        # koki:libs:end\n" ++
  "      ];\n" ++
  "\n" ++
  "      # `--include` flags for the compiler.\n" ++
  "      kokaLibArgs = pkgs:\n" ++
  "        builtins.concatStringsSep \" \" (map (d: \"--include=#{d}\") (kokaLibsFor pkgs));\n" ++
  "\n" ++
  "      # The same list as a `koka.json` `include_dirs` array, which is what\n" ++
  "      # editors and the Koka language server read.\n" ++
  "      kokaJson = pkgs:\n" ++
  "        ''{\"include_dirs\":[#{builtins.concatStringsSep \",\" (map (d: \"\\\"#{d}\\\"\") (kokaLibsFor pkgs))}]}'';\n" ++
  "    in\n" ++
  "    {\n"

// Keep the interpreter output of generated sources out of the build.
val src-filter : string =
  "          src = pkgs.lib.cleanSourceWith {\n" ++
  "            src = self;\n" ++
  "            filter = path: type:\n" ++
  "              let base = baseNameOf (toString path);\n" ++
  "              in !(builtins.elem base [ \"result\" \"koka.json\" \".koka\" ]);\n" ++
  "          };\n"

val gitignore : string =
  "# Koka build output\n" ++
  ".koka/\n" ++
  "\n" ++
  "# Written by the dev shell on every `nix develop`\n" ++
  "koka.json\n" ++
  "\n" ++
  "# Nix\n" ++
  "result\n" ++
  "result-*\n" ++
  "\n" ++
  "# Compiled binaries\n" ++
  "{{name}}\n" ++
  "test-bin\n"

val license : string =
  "MIT License\n" ++
  "\n" ++
  "Copyright (c) {{year}} {{author}}\n" ++
  "\n" ++
  "Permission is hereby granted, free of charge, to any person obtaining a copy\n" ++
  "of this software and associated documentation files (the \"Software\"), to deal\n" ++
  "in the Software without restriction, including without limitation the rights\n" ++
  "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n" ++
  "copies of the Software, and to permit persons to whom the Software is\n" ++
  "furnished to do so, subject to the following conditions:\n" ++
  "\n" ++
  "The above copyright notice and this permission notice shall be included in all\n" ++
  "copies or substantial portions of the Software.\n" ++
  "\n" ++
  "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n" ++
  "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n" ++
  "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n" ++
  "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n" ++
  "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n" ++
  "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n" ++
  "SOFTWARE.\n"

// ---------- per-kind templates ----------

val bin-flake : string = flake-preamble ++
  "\n" ++
  "      packages = forAllSystems (pkgs: system: {\n" ++
  "        default = pkgs.stdenv.mkDerivation {\n" ++
  "          pname = \"{{name}}\";\n" ++
  "          version = \"{{version}}\";\n" ++
  src-filter ++
  "          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];\n" ++
  "\n" ++
  "          buildPhase = ''\n" ++
  "            runHook preBuild\n" ++
  "            koka -o {{name}} #{kokaLibArgs pkgs} main.kk\n" ++
  "            runHook postBuild\n" ++
  "          '';\n" ++
  "\n" ++
  "          installPhase = ''\n" ++
  "            runHook preInstall\n" ++
  "            install -Dm755 {{name}} $out/bin/{{name}}\n" ++
  "            runHook postInstall\n" ++
  "          '';\n" ++
  "\n" ++
  "          meta = {\n" ++
  "            description = \"{{desc}}\";\n" ++
  "            mainProgram = \"{{name}}\";\n" ++
  "            platforms = pkgs.lib.platforms.unix;\n" ++
  "          };\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      apps = forAllSystems (pkgs: system: {\n" ++
  "        default = {\n" ++
  "          type = \"app\";\n" ++
  "          program = \"#{self.packages.#{system}.default}/bin/{{name}}\";\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      devShells = forAllSystems (pkgs: system: {\n" ++
  "        default = pkgs.mkShell {\n" ++
  "          packages = [ pkgs.koka ];\n" ++
  "          shellHook = \"printf '%s\\\\n' '#{kokaJson pkgs}' > \\\"$PWD/koka.json\\\"\";\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      checks = forAllSystems (pkgs: system: {\n" ++
  "        build = self.packages.#{system}.default;\n" ++
  "      });\n" ++
  "    };\n" ++
  "}\n"

val test-flake : string = flake-preamble ++
  "\n" ++
  "      packages = forAllSystems (pkgs: system: {\n" ++
  "        default = pkgs.stdenv.mkDerivation {\n" ++
  "          pname = \"{{name}}\";\n" ++
  "          version = \"{{version}}\";\n" ++
  src-filter ++
  "          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];\n" ++
  "\n" ++
  "          buildPhase = ''\n" ++
  "            runHook preBuild\n" ++
  "            koka -o {{name}} #{kokaLibArgs pkgs} main.kk\n" ++
  "            runHook postBuild\n" ++
  "          '';\n" ++
  "\n" ++
  "          installPhase = ''\n" ++
  "            runHook preInstall\n" ++
  "            install -Dm755 {{name}} $out/bin/{{name}}\n" ++
  "            runHook postInstall\n" ++
  "          '';\n" ++
  "\n" ++
  "          meta = {\n" ++
  "            description = \"{{desc}}\";\n" ++
  "            mainProgram = \"{{name}}\";\n" ++
  "            platforms = pkgs.lib.platforms.unix;\n" ++
  "          };\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      apps = forAllSystems (pkgs: system: {\n" ++
  "        default = {\n" ++
  "          type = \"app\";\n" ++
  "          program = \"#{self.packages.#{system}.default}/bin/{{name}}\";\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      devShells = forAllSystems (pkgs: system: {\n" ++
  "        default = pkgs.mkShell {\n" ++
  "          packages = [ pkgs.koka ];\n" ++
  "          shellHook = \"printf '%s\\\\n' '#{kokaJson pkgs}' > \\\"$PWD/koka.json\\\"\";\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      # `koki check` runs these. A test that stops making the build fail is a\n" ++
  "      # test that has stopped being a test.\n" ++
  "      checks = forAllSystems (pkgs: system: {\n" ++
  "        tests = pkgs.stdenv.mkDerivation {\n" ++
  "          pname = \"{{name}}-tests\";\n" ++
  "          version = \"{{version}}\";\n" ++
  "          src = self;\n" ++
  "          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];\n" ++
  "          dontConfigure = true;\n" ++
  "          dontInstall = true;\n" ++
  "\n" ++
  "          buildPhase = ''\n" ++
  "            runHook preBuild\n" ++
  "            koka #{kokaLibArgs pkgs} -o test-bin test/test.kk\n" ++
  "            ./test-bin\n" ++
  "            runHook postBuild\n" ++
  "            touch $out\n" ++
  "          '';\n" ++
  "        };\n" ++
  "      });\n" ++
  "    };\n" ++
  "}\n"

val lib-flake : string = flake-preamble ++
  "\n" ++
  "      packages = forAllSystems (pkgs: system: {\n" ++
  "        default = pkgs.stdenv.mkDerivation {\n" ++
  "          pname = \"{{name}}\";\n" ++
  "          version = \"{{version}}\";\n" ++
  src-filter ++
  "          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];\n" ++
  "\n" ++
  "          buildPhase = ''\n" ++
  "            runHook preBuild\n" ++
  "            koka -l --output={{module}} --builddir=\"$PWD/.koka-build\" src/{{module}}.kk\n" ++
  "            runHook postBuild\n" ++
  "          '';\n" ++
  "\n" ++
  "          # A Koka library is its source: consumers resolve it with\n" ++
  "          # `--include=<includePath>` and compile against these modules.\n" ++
  "          installPhase = ''\n" ++
  "            runHook preInstall\n" ++
  "            install -Dm644 src/{{module}}.kk \\\n" ++
  "              $out/share/koka/#{pkgs.koka.version}/{{module}}.kk\n" ++
  "            runHook postInstall\n" ++
  "          '';\n" ++
  "\n" ++
  "          meta = {\n" ++
  "            description = \"{{desc}}\";\n" ++
  "            platforms = pkgs.lib.platforms.unix;\n" ++
  "          };\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      # How a consuming flake reaches this library. `koki add` writes\n" ++
  "      # `self.inputs.<input>.kokaLibraries.<system>.{{module}}.includePath`\n" ++
  "      # when this flake is added as a dependency.\n" ++
  "      kokaLibraries = forAllSystems (pkgs: system: {\n" ++
  "        {{module}} = {\n" ++
  "          path = self.packages.#{system}.default;\n" ++
  "          includePath = \"#{self.packages.#{system}.default}/share/koka/#{pkgs.koka.version}\";\n" ++
  "          version = pkgs.koka.version;\n" ++
  "          libVersion = self.packages.#{system}.default.version;\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      devShells = forAllSystems (pkgs: system: {\n" ++
  "        default = pkgs.mkShell {\n" ++
  "          packages = [ pkgs.koka ];\n" ++
  "          shellHook = \"printf '%s\\\\n' '#{kokaJson pkgs}' > \\\"$PWD/koka.json\\\"\";\n" ++
  "        };\n" ++
  "      });\n" ++
  "\n" ++
  "      checks = forAllSystems (pkgs: system: {\n" ++
  "        build = self.packages.#{system}.default;\n" ++
  "      });\n" ++
  "    };\n" ++
  "}\n"

val bin-main : string =
  "module main\n" ++
  "\n" ++
  "fun greet(who : string) : string\n" ++
  "  \"Hello, \" ++ who ++ \"!\"\n" ++
  "\n" ++
  "fun main()\n" ++
  "  println(greet(\"{{name}}\"))\n"

val test-main : string =
  "module main\n" ++
  "\n" ++
  "// `pub` because the test module imports it: a test that cannot reach the\n" ++
  "// thing it is testing is not a test.\n" ++
  "pub fun greet(who : string) : string\n" ++
  "  \"Hello, \" ++ who ++ \"!\"\n" ++
  "\n" ++
  "fun main()\n" ++
  "  println(greet(\"{{name}}\"))\n"

val test-suite : string =
  "module test\n" ++
  "\n" ++
  "import main\n" ++
  "\n" ++
  "// `assert` aborts on failure, so a failing test takes the whole derivation\n" ++
  "// with it and `nix flake check` reports it as a failed check.\n" ++
  "fun test-greet()\n" ++
  "  val msg = greet(\"world\")\n" ++
  "  assert(\"greet greets the world\", msg == \"Hello, world!\")\n" ++
  "\n" ++
  "fun main() : io int\n" ++
  "  test-greet()\n" ++
  "  println(\"1 test passed\")\n" ++
  "  return 0\n"

val lib-module : string =
  "module {{module}}\n" ++
  "\n" ++
  "// A Koka library is a set of modules that other code imports by name. Put\n" ++
  "// the module file at the root of the include directory installed by the\n" ++
  "// flake, and `import {{module}}` will resolve for anyone who adds this\n" ++
  "// flake as a dependency.\n" ++
  "pub fun {{module}}/greet(who : string) : string\n" ++
  "  \"Hello, \" ++ who ++ \", from {{name}}\"\n"

val lib-example : string =
  "module example\n" ++
  "\n" ++
  "// Run this from the dev shell, where the library is on the include path:\n" ++
  "//\n" ++
  "//     nix develop\n" ++
  "//     koka -o example example.kk && ./example\n" ++
  "import {{module}}\n" ++
  "\n" ++
  "fun main()\n" ++
  "  println({{module}}/greet(\"world\"))\n"

fun readme-for(s : settings) : string
  if s.kind == "lib" then
    "# {{name}}\n" ++
    "\n" ++
    "{{desc}}\n" ++
    "\n" ++
    "## Using it\n" ++
    "\n" ++
    "From another Koka project:\n" ++
    "\n" ++
    "    koki add path:{{name}}\n" ++
    "\n" ++
    "or by hand, in that project's `flake.nix`:\n" ++
    "\n" ++
    "    inputs.my-lib.url = \"path:../{{name}}\";\n" ++
    "\n" ++
    "```nix\n" ++
    "kokaLibsFor = pkgs: [\n" ++
    "  self.inputs.my-lib.kokaLibraries.#{pkgs.stdenv.hostPlatform.system}.{{module}}.includePath\n" ++
    "];\n" ++
    "```\n" ++
    "\n" ++
    "## Layout\n" ++
    "\n" ++
    "- `src/{{module}}.kk` — the library itself\n" ++
    "- `example.kk` — a tiny program that imports it\n" ++
    "- `flake.nix` — the build, and the `kokaLibraries` output other flakes use\n" ++
    "\n" ++
    "## Commands\n" ++
    "\n" ++
    "    koki build      # nix build\n" ++
    "    koki check      # nix flake check\n" ++
    "    koki dev        # nix develop\n"
  else
    "# {{name}}\n" ++
    "\n" ++
    "{{desc}}\n" ++
    "\n" ++
    "## Layout\n" ++
    "\n" ++
    "- `main.kk` — the program\n" ++
    "- `flake.nix` — the whole build; `koki add` manages the marked regions\n" ++
    "- `koka.json` — generated by the dev shell, not checked in\n" ++
    "\n" ++
    "## Commands\n" ++
    "\n" ++
    "    koki dev        # nix develop, with koka and the include path set up\n" ++
    "    koki run        # build and run the program\n" ++
    "    koki build      # nix build\n" ++
    "    koki check      # nix flake check\n" ++
    "    koki add <dep>  # add a Koka library as a flake input\n"

// ---------- assembling ----------

// The `flake.nix` body for these settings. Exposed so the test suite can
// exercise the flake model against a file koki would really write, rather
// than against a fixture that can drift from the template.
pub fun render-flake(s : settings) : string
  match s.kind
    "lib" -> render(lib-flake, s)
    "test" -> render(test-flake, s)
    _ -> render(bin-flake, s)

pub fun template-files(s : settings) : list<newfile>
  val flake = render-flake(s)
  val base = [
    Newfile("flake.nix", flake),
    Newfile(".gitignore", render(gitignore, s)),
    Newfile("README.md", render(readme-for(s), s)),
    Newfile("LICENSE", render(license, s)),
  ]
  match s.kind
    "lib" -> base ++ [
      Newfile("src/" ++ str-snake(s.name) ++ ".kk", render(lib-module, s)),
      Newfile("example.kk", render(lib-example, s)),
    ]
    "test" -> base ++ [
      Newfile("main.kk", render(test-main, s)),
      Newfile("test/test.kk", render(test-suite, s)),
    ]
    _ -> base ++ [ Newfile("main.kk", render(bin-main, s)) ]
