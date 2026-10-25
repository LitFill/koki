{
  description = "koki — the Koka project manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # koki:inputs:start
    util-kk.url = "github:LitFill/util-kk";
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
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system} system);

      baseVersion = "0.2.0";

      revision = self.shortRev or self.dirtyShortRev or null;

      fullVersion = baseVersion + (if revision == null then "" else "-${revision}");

      # One Koka include directory per dependency. `koki add` writes the
      # lines between the markers below and `koki remove` takes them out;
      # the compiler flags and the editor include list further down are both
      # derived from them, so they cannot drift out of step with each other.
      kokaLibsFor = pkgs: [
        # koki:libs:start
        "${
          self.inputs.util-kk.packages.${pkgs.stdenv.hostPlatform.system}.default
        }/share/koka/${pkgs.koka.version}"
        # koki:libs:end
      ];

      # `--include` flags for the compiler.
      kokaLibArgs = pkgs: builtins.concatStringsSep " " (map (d: "--include=${d}") (kokaLibsFor pkgs));

      # The same list as a `koka.json` `include_dirs` array, which is what
      # editors and the Koka language server read.
      kokaJson =
        pkgs:
        ''{"include_dirs":[${builtins.concatStringsSep "," (map (d: "\"${d}\"") (kokaLibsFor pkgs))}]}'';

      # Shared by the package and the test check.
      kokiSrc =
        pkgs:
        pkgs.lib.cleanSourceWith {
          src = self;
          filter =
            path: type:
            !(builtins.elem (baseNameOf (toString path)) [
              "result"
              "koka.json"
              ".koka"
              "koki"
            ]);
        };
    in
    {
      packages = forAllSystems (
        pkgs: system: {
          default = pkgs.stdenv.mkDerivation {
            pname = "koki";
            version = fullVersion; # also exposed as `.version` / `lib.getVersion`
            src = kokiSrc pkgs;

            nativeBuildInputs = [
              pkgs.koka
              pkgs.stdenv.cc
            ];

            buildPhase = ''
              runHook preBuild
              # Bake the full version (with revision) into `koki --version`.
              # --replace-fail aborts the build if the literal ever changes,
              # instead of silently shipping an unstamped binary.
              substituteInPlace src/cli.kk \
                --replace-fail '"${baseVersion}"' '"${fullVersion}"'
              koka -o koki -O1 ${kokaLibArgs pkgs} main.kk
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm755 koki $out/bin/koki
              runHook postInstall
            '';

            meta = {
              description = "koki — the Koka project manager";
              longDescription = ''
                koki creates and manages Koka projects. A Koka project is a
                directory with a flake.nix; koki writes that file, keeps its
                dependency list, and hands the actual building to Nix.
              '';
              homepage = "https://github.com/LitFill/koki";
              license = pkgs.lib.licenses.mit;
              mainProgram = "koki";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        }
      );

      apps = forAllSystems (
        pkgs: system: {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/koki";
          };
        }
      );

      devShells = forAllSystems (
        pkgs: system: {
          default = pkgs.mkShell {
            packages = [ pkgs.koka ];
            shellHook = "printf '%s\\n' '${kokaJson pkgs}' > \"$PWD/koka.json\"";
          };
        }
      );

      # The test suite is a check rather than a separate target, so that a
      # regression fails `nix flake check` and therefore any CI running it.
      checks = forAllSystems (
        pkgs: system: {
          tests = pkgs.stdenv.mkDerivation {
            pname = "koki-tests";
            version = baseVersion;
            src = kokiSrc pkgs;
            nativeBuildInputs = [
              pkgs.koka
              pkgs.stdenv.cc
            ];
            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              runHook preBuild
              koka ${kokaLibArgs pkgs} -o test-bin test/run.kk
              ./test-bin
              runHook postBuild
              touch $out
            '';
          };
        }
      );
    };
}
