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
          goPkg = pkgs.go_1_27; # pin latest Go, also dogfoods the goPkg knob
          prettier = true; # dogfood web/doc formatting (examples/minimal/README.md)
          # Dogfood the formatter escape hatches: shfmt is not a program this
          # lib enables, and "sh" is not an extension it collects, so
          # examples/minimal/hello.sh is only reached if both knobs work.
          fmtExts = [ "sh" ];
          treefmtExtra = {
            programs.shfmt.enable = true;
            # prettier 3.8 reads .editorconfig and walks *past* the project
            # root to find one, so a developer's ~/.editorconfig restyles the
            # tree locally while the sandboxed check — which has no home dir —
            # disagrees. Pin it off so both see the same rules.
            settings.formatter.prettier.options = [ "--no-editorconfig" ];
          };
        };
      in
      {
        packages.default = fc.goBuild common;
        formatter = fc.formatter common;
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.go_1_27 pkgs.gopls pkgs.golangci-lint pkgs.gofumpt pkgs.prek pkgs.gnumake ];
        };
        checks = {
          build = fc.goBuild common;
          gotest = fc.goTest common;
          golangci-lint = fc.goLint common;
          generate = fc.goGenerate common;
          formatting = fc.goFormat common;
        };
      }
    );
}
