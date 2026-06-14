# flake-checks

Reusable, cache-friendly Nix flake checks. One function per check, composed in
your flake's `checks` so `nix build .#checks.<system>.<name>` is the CI gate.

## Use

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-checks.url = "github:kradalby/flake-checks";
    flake-checks.inputs.nixpkgs.follows = "nixpkgs"; # required: shared store paths / cache
  };

  outputs = { self, nixpkgs, flake-utils, flake-checks, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        fc = flake-checks.lib;
        common = {
          inherit pkgs;
          root = ./.;
          pname = "myapp";
          version = "0.1.0";
          vendorHash = "sha256-…"; # null if dep-free or vendored in-tree
          goPkg = pkgs.go_1_26;    # optional, defaults to pkgs.go
        };
      in
      {
        packages.default = fc.goBuild common;
        formatter = fc.formatter common;
        checks = {
          build = fc.goBuild common;
          gotest = fc.goTest common;
          golangci-lint = fc.goLint common;
          formatting = fc.goFormat common;
        };
      });
}
```

## Functions (Go)

| Function | Output | Notes |
|----------|--------|-------|
| `goBuild common` | `buildGoModule` package | use for `packages.default` and `checks.build` |
| `goTest common` | `go test ./...` check | `goRace = true` adds `-race` (CGO); `goSkip = [ "Pat" ]` |
| `goLint common` | `golangci-lint run ./...` check | full tree |
| `goFormat common` | treefmt check | gofumpt + goimports + nixpkgs-fmt |
| `formatter common` | `nix fmt` wrapper | the flake's `formatter` output |

`common` keys: `pkgs`, `root`, `pname`, `vendorHash` (required); `version`, `goPkg`,
`embedDirs` (extra `//go:embed` dirs), `extraSrc`, `excludeSrc`, `goSkip`, `goRace`,
`goTags`, `proxyVendor` (optional). Each function takes `...` and ignores keys it
doesn't use, so one `common` set drives them all.

`proxyVendor = true` fetches deps via the module proxy (`go mod download`) instead
of `go mod vendor`, so build-tag-only deps (e.g. a `//go:build e2e` import) resolve
offline. It yields a different `vendorHash` than vendor mode — give that lane its own.

Each check's `src` is `lib.fileset`-filtered to only its inputs, so unrelated edits
(docs, CI, other lockfile inputs) hit the binary cache instead of rebuilding.
