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

| Function             | Output                          | Notes                                                                   |
| -------------------- | ------------------------------- | ----------------------------------------------------------------------- |
| `goBuild common`     | `buildGoModule` package         | use for `packages.default` and `checks.build`                           |
| `goTest common`      | `go test ./...` check           | `goRace = true` adds `-race` (CGO); `goSkip = [ "Pat" ]`; `testWrapper = "xvfb-run"`; `retries = 3` for flaky suites |
| `goLint common`      | `golangci-lint run ./...` check | full tree                                                               |
| `goGenerate common`  | `go generate` drift check       | regenerates in the sandbox, fails on diff; `generateCommand`, `preGen`/`postGen` |
| `goFormat common`    | treefmt check                   | gofumpt + goimports + nixpkgs-fmt; `prettier = true` adds web/doc files |
| `formatter common`   | `nix fmt` wrapper               | the flake's `formatter` output                                          |

`common` keys: `pkgs`, `root`, `pname`, `vendorHash` (required); `version`, `goPkg`,
`embedDirs` (extra `//go:embed` dirs), `extraSrc`, `excludeSrc`, `goSkip`, `goRace`,
`goTags`, `proxyVendor`, `goCache`, `prettier`, `fmtExclude` (optional). Each function
takes `...` and ignores keys it doesn't use, so one `common` set drives them all.

`goCache` accepts a derivation whose setup hook seeds `$TMPDIR/go-cache` with
precompiled dependencies (e.g. [numtide/build-go-cache](https://github.com/numtide/build-go-cache));
it is wired into the build and every check. Go's cache keys include build flags, so
the cache must be built with the same `-trimpath`/`-race`/CGO configuration as its
consumer or every lookup misses.

`prettier = true` formats md/yaml/ts/js/css/scss/sass/html/json through prettier in
addition to the Go/Nix formatters (off by default; `fmtExclude` drops paths, e.g.
generated dirs).

`proxyVendor = true` fetches deps via the module proxy (`go mod download`) instead
of `go mod vendor`, so build-tag-only deps (e.g. a `//go:build e2e` import) resolve
offline. It yields a different `vendorHash` than vendor mode — give that lane its own.

Each check's `src` is `lib.fileset`-filtered to only its inputs, so unrelated edits
(docs, CI, other lockfile inputs) hit the binary cache instead of rebuilding. Every
directory named `testdata` (the `go test` convention) is included automatically,
anywhere in the tree; only `//go:embed` targets and unconventional fixtures need
`embedDirs`/`extraSrc`.
