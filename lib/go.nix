# Cache-friendly Go flake checks, one function per check.
#
#   lib.goBuild   common   → packages.default / checks.build
#   lib.goTest    common   → checks.gotest        (+ goRace / goSkip)
#   lib.goLint    common   → checks.golangci-lint
#   lib.goFormat  common   → checks.formatting    (treefmt)
#   lib.formatter common   → formatter            (`nix fmt`)
#
# `common` is one attrset shared across the calls; each function takes `...`
# and ignores keys it doesn't use:
#
#   common = { inherit pkgs; root = ./.; pname = "app";
#              vendorHash = "sha256-…"; goPkg = pkgs.go_1_26; };
#
# Each check's src is fileset-filtered to only its inputs, so unrelated edits
# hit the binary cache instead of rebuilding. Tests/lint run fully offline:
# vendored goModules tree (-mod=vendor), or GOPROXY=off when vendorHash = null.
{ treefmt-nix }:
let
  # Private: derive the shared context once from the common args.
  mkCtx =
    { pkgs
    , root
    , pname ? "app"
    , version ? "0.0.0"
    , vendorHash
    , goPkg ? pkgs.go
    , embedDirs ? [ ] # extra //go:embed dirs, e.g. [ (root + "/static") ]
    , extraSrc ? [ ] # extra files/dirs tests read, e.g. [ (root + "/fixture.json") ]
    , excludeSrc ? [ ] # dirs to drop, e.g. a nested module [ (root + "/provider") ]
    , subPackages ? null # buildGoModule subPackages, e.g. [ "cmd/app" ]
    , ldflags ? [ ] # buildGoModule ldflags
    , env ? { } # buildGoModule env, e.g. { CGO_ENABLED = "0"; }
    , proxyVendor ? false # fetch via `go mod download` (module proxy) instead
      # of `go mod vendor`; needed when deps live only behind a build tag
      # (e.g. //go:build e2e), which `go mod vendor` drops.
    , ...
    }:
    let
      lib = pkgs.lib;
      fs = lib.fileset;
      goSrc = fs.toSource {
        inherit root;
        # Whitelist Go inputs (incl. the repo's lint config so golangci-lint uses
        # it), minus any committed vendor/ tree (the checks vendor via goModules).
        fileset = fs.difference
          (fs.unions ([
            (root + "/go.mod")
            (fs.maybeMissing (root + "/go.sum"))
            (fs.fileFilter (f: f.hasExt "go") root)
            (fs.maybeMissing (root + "/testdata"))
            (fs.maybeMissing (root + "/.golangci.yml"))
            (fs.maybeMissing (root + "/.golangci.yaml"))
            (fs.maybeMissing (root + "/.golangci.toml"))
          ] ++ map fs.maybeMissing (embedDirs ++ extraSrc)))
          (fs.unions (map fs.maybeMissing ([ (root + "/vendor") ] ++ excludeSrc)));
      };
      pkg = (pkgs.buildGoModule.override { go = goPkg; }) ({
        inherit pname version vendorHash proxyVendor;
        src = goSrc;
        doCheck = false;
        inherit ldflags;
      }
      // lib.optionalAttrs (subPackages != null) { inherit subPackages; }
      // lib.optionalAttrs (env != { }) { inherit env; });
      goEnv = ''
        export HOME=$TMPDIR
        export GOCACHE=$TMPDIR/go-build
      '' + (if vendorHash == null then ''
        export GOFLAGS=-mod=mod
        export GOPROXY=off
      '' else if proxyVendor then ''
        # goModules is the module download cache (proxy layout); serve it as a
        # file:// GOPROXY so tag-only deps resolve offline under -mod=mod.
        export GOFLAGS=-mod=mod
        export GOPROXY=file://${pkg.goModules}
        export GOSUMDB=off
      '' else ''
        export GOFLAGS=-mod=vendor
        ln -s ${pkg.goModules} vendor
      '');
    in
    { inherit pkgs lib goSrc pkg goEnv pname goPkg; };

  # goFmt picks the Go formatter: "gofumpt" (default), "gofmt", or "off"
  # (nix-only; let golangci-lint enforce Go formatting).
  treefmtFor = pkgs: goFmt: treefmt-nix.lib.evalModule pkgs {
    projectRootFile = "go.mod";
    programs = {
      gofumpt.enable = goFmt == "gofumpt";
      gofmt.enable = goFmt == "gofmt";
      goimports.enable = goFmt != "off";
      nixpkgs-fmt.enable = true;
    };
  };
in
{
  goBuild = args: (mkCtx args).pkg;

  # nativeCheckInputs: extra tools on PATH during the test (e.g. softhsm, a db).
  # testEnv: extra shell run before `go test` (export integration env, etc.).
  # testPackages: package pattern(s) to test, defaults to the whole module.
  # goTags: build tags, e.g. [ "e2e" ]. name: override the derivation name.
  # testFlags: extra `go test` flags, e.g. [ "-timeout=60m" ].
  goTest =
    { goSkip ? [ ], goRace ? false, nativeCheckInputs ? [ ], testEnv ? ""
    , testPackages ? "./...", goTags ? [ ], testFlags ? [ ], name ? null, ...
    }@args:
    let
      c = mkCtx args;
      raceFlag = c.lib.optionalString goRace "-race";
      tagsFlag = c.lib.optionalString (goTags != [ ]) "-tags=${c.lib.concatStringsSep "," goTags}";
      skipFlag = c.lib.optionalString (goSkip != [ ]) "-skip '${c.lib.concatStringsSep "|" goSkip}'";
      flagsStr = c.lib.concatStringsSep " " testFlags;
    in
    c.pkgs.stdenv.mkDerivation {
      name = if name != null then name else "${c.pname}-gotest";
      src = c.goSrc;
      nativeBuildInputs = [ c.goPkg ] ++ nativeCheckInputs;
      buildPhase = ''
        ${c.goEnv}
        ${testEnv}
        go test ${raceFlag} ${tagsFlag} ${flagsStr} ${skipFlag} ${testPackages}
      '';
      installPhase = "touch $out";
    };

  # golangciLint: override the golangci-lint package (e.g. one built with a
  # newer Go when go.mod targets a version above nixpkgs' default).
  goLint =
    { golangciLint ? null, ... }@args:
    let
      c = mkCtx args;
      gcl = if golangciLint != null then golangciLint else c.pkgs.golangci-lint;
    in
    c.pkgs.stdenv.mkDerivation {
      name = "${c.pname}-golangci-lint";
      src = c.goSrc;
      nativeBuildInputs = [ c.goPkg gcl ];
      buildPhase = ''
        ${c.goEnv}
        export GOLANGCI_LINT_CACHE=$TMPDIR/golangci
        golangci-lint run ./...
      '';
      installPhase = "touch $out";
    };

  # fmtExclude: dirs/files to skip (generated code, vendored deploy configs, …).
  goFormat =
    { pkgs, root, fmtExclude ? [ ], goFmt ? "gofumpt", ... }:
    let
      fs = pkgs.lib.fileset;
      base = fs.unions [
        (root + "/go.mod")
        (fs.fileFilter (f: f.hasExt "go") root)
        (fs.fileFilter (f: f.hasExt "nix") root)
      ];
      fileset =
        if fmtExclude == [ ]
        then base
        else fs.difference base (fs.unions (map fs.maybeMissing fmtExclude));
      fmtSrc = fs.toSource { inherit root; inherit fileset; };
    in
    (treefmtFor pkgs goFmt).config.build.check fmtSrc;

  formatter = { pkgs, goFmt ? "gofumpt", ... }: (treefmtFor pkgs goFmt).config.build.wrapper;
}
