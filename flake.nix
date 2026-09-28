{
  description = "koki — the Koka project manager";

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

      packages = forAllSystems (pkgs: system: {
        default = pkgs.stdenv.mkDerivation {
          pname = "koki";
          version = "0.1.0";
          src = pkgs.lib.cleanSourceWith {
            src = self;
            filter = path: type:
              let base = baseNameOf (toString path);
              in !(builtins.elem base [ "result" "koka.json" ".koka" "koki" ]);
          };
          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];

          buildPhase = ''
            runHook preBuild
            koka -o koki ${kokaLibArgs pkgs} main.kk
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 koki $out/bin/koki
            runHook postInstall
          '';

          # `koki --version` reports this, so keep the two in step.
          passthru.version = "0.1.0";

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
      });

      apps = forAllSystems (pkgs: system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/koki";
        };
      });

      devShells = forAllSystems (pkgs: system: {
        default = pkgs.mkShell {
          packages = [ pkgs.koka ];
          shellHook = "printf '%s\\n' '${kokaJson pkgs}' > \"$PWD/koka.json\"";
        };
      });

      # The test suite is a check rather than a separate target, so that a
      # regression fails `nix flake check` and therefore any CI running it.
      checks = forAllSystems (pkgs: system: {
        tests = pkgs.stdenv.mkDerivation {
          pname = "koki-tests";
          version = "0.1.0";
          src = pkgs.lib.cleanSourceWith {
            src = self;
            filter = path: type:
              let base = baseNameOf (toString path);
              in !(builtins.elem base [ "result" "koka.json" ".koka" "koki" ]);
          };
          nativeBuildInputs = [ pkgs.koka pkgs.stdenv.cc ];
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
      });
    };
}
