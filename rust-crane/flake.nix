
{
  inputs = {
    # We use stable nixpkgs here because otherwise we may end up with a
    # bleeding-edge glibc interpreter, and nobody else will be able to run our
    # binaries.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    flake-utils,
    rust-overlay,
    advisory-db,
    crane,
    nixpkgs,
  }:
  # We wrap the entire output set in this flake-utils function, which builds the flake
  # for each architecture type supported by nix.
    flake-utils.lib.eachDefaultSystem (
      system: let
        # This sets up nixpkgs, where we will pull our dependencies from
        pkgs = nixpkgs.legacyPackages.${system};
        pkgsMusl = import nixpkgs {
          inherit system;
          overlays = [(import rust-overlay)];
        };

        inherit (pkgs) lib;

        craneLib = crane.mkLib pkgs;

        # TODO: should check to make sure this is only used when on x86
        craneLibMusl = (crane.mkLib pkgsMusl).overrideToolchain (p:
          p.rust-bin.stable.latest.default.override {
            targets = ["x86_64-unknown-linux-musl"];
          });

        src = craneLib.cleanCargoSource ./.;
        commonArgs = {
          inherit src;
          strictDeps = true;
          # Here we can add non-rust dependencies that our program requires at build time.
          nativeBuildInputs = with pkgs; [
            openssl
            patchelf #
          ];
          # Here we can add non-rust dependencies that our program requires at run time.
          buildInputs = with pkgs;
            [
              docker
              pkg-config
            ]
            ++ lib.optionals pkgs.stdenv.isDarwin [
              libiconv
            ];
        };
        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        cargoMuslArtifacts = craneLibMusl.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        myPackage = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
          }
        );
        myPackage-musl = craneLibMusl.buildPackage (
          commonArgs
          // {
            inherit cargoMuslArtifacts;
            src = craneLibMusl.cleanCargoSource ./.;

            CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
            CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
          }
        );
      in {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit myPackage;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          myPackage-clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

          # myPackage-doc = craneLib.cargoDoc (
          #   commonArgs
          #   // {
          #     inherit cargoArtifacts;
          #     # This can be commented out or tweaked as necessary, e.g. set to
          #     # `--deny rustdoc::broken-intra-doc-links` to only enforce that lint
          #     env.RUSTDOCFLAGS = "--deny warnings";
          #   }
          # );

          # Check formatting
          myPackage-fmt = craneLib.cargoFmt {
            inherit src;
          };

          myPackage-toml-fmt = craneLib.taploFmt {
            src = pkgs.lib.sources.sourceFilesBySuffices src [".toml"];
            # taplo arguments can be further customized below as needed
            # taploExtraArgs = "--config ./taplo.toml";
          };

          # Audit dependencies
          # myPackage-audit = craneLib.cargoAudit {
          #   inherit src advisory-db;
          # };

          # # Audit licenses
          # myPackage-deny = craneLib.cargoDeny {
          #   inherit src;
          # };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on `myPackage` if you do not want
          # the tests to run twice
          # myPackage-nextest = craneLib.cargoNextest (
          #   commonArgs
          #   // {
          #     inherit cargoArtifacts;
          #     partitions = 1;
          #     partitionType = "count";
          #     cargoNextestPartitionsExtraArgs = "--no-tests=pass";
          #   }
          # );
        };

        packages = {
          default = myPackage;
          fhs-link = myPackage.overrideAttrs (_: {
            # Fixup linker to make it FHS-compliant.
            fixupPhase = ''
              patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 $out/bin/myPackage
            '';
          });
          musl = myPackage-musl;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = myPackage;
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          packages = with pkgs; [
            sops
            cargo
            clippy
            cmake
            nixpkgs-fmt
            rustc
            rustfmt
            cargo-edit
          ];
        };
      }
    );
}
