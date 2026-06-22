{
  description = "Reusable, cache-friendly Nix flake checks (Go).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , treefmt-nix
    }:
    {
      lib = import ./lib/go.nix { inherit treefmt-nix; };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        fc = self.lib;
        # Dogfood the helpers against a minimal module so the lib has its own CI.
        common = {
          inherit pkgs;
          root = ./examples/minimal;
          pname = "example";
          vendorHash = null;
          goPkg = pkgs.go_1_26; # pin latest Go, also dogfoods the goPkg knob
          prettier = true; # dogfood web/doc formatting (examples/minimal/README.md)
        };
      in
      {
        packages.default = fc.goBuild common;
        formatter = fc.formatter common;
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.go_1_26 pkgs.gopls pkgs.golangci-lint pkgs.gofumpt pkgs.prek pkgs.gnumake ];
        };
        checks = {
          build = fc.goBuild common;
          gotest = fc.goTest common;
          golangci-lint = fc.goLint common;
          formatting = fc.goFormat common;
        };
      }
    );
}
