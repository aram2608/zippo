{
  description = "zippo: Zig text editor dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig-overlay }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      zig = zig-overlay.packages.${system}."0.16.0";
    in {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "zippo";
        version = "0.0.0";
        src = ./.;

        nativeBuildInputs = [ zig ];

        dontConfigure = true;
        dontInstall = true;

        buildPhase = ''
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          zig build --release=safe --prefix $out
        '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ zig ];

        shellHook = ''
          echo "zippo dev shell: zig $(zig version)"
        '';
      };
    };
}
