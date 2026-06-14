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
      pkg = (pkgs.buildGoModule.override { go = goPkg; }) {
        inherit pname version vendorHash;
        src = goSrc;
        doCheck = false;
      };
      goEnv = ''
        export HOME=$TMPDIR
        export GOCACHE=$TMPDIR/go-build
      '' + (if vendorHash == null then ''
        export GOFLAGS=-mod=mod
        export GOPROXY=off
      '' else ''
        export GOFLAGS=-mod=vendor
        ln -s ${pkg.goModules} vendor
      '');
    in
    { inherit pkgs lib goSrc pkg goEnv pname goPkg; };

  treefmtFor = pkgs: treefmt-nix.lib.evalModule pkgs {
    projectRootFile = "go.mod";
    programs = {
      gofumpt.enable = true;
      goimports.enable = true;
      nixpkgs-fmt.enable = true;
    };
  };
in
{
  goBuild = args: (mkCtx args).pkg;

  # nativeCheckInputs: extra tools on PATH during the test (e.g. softhsm, a db).
  # testEnv: extra shell run before `go test` (export integration env, etc.).
  goTest =
    { goSkip ? [ ], goRace ? false, nativeCheckInputs ? [ ], testEnv ? "", ... }@args:
    let
      c = mkCtx args;
      raceFlag = c.lib.optionalString goRace "-race";
      skipFlag = c.lib.optionalString (goSkip != [ ]) "-skip '${c.lib.concatStringsSep "|" goSkip}'";
    in
    c.pkgs.stdenv.mkDerivation {
      name = "${c.pname}-gotest";
      src = c.goSrc;
      nativeBuildInputs = [ c.goPkg ] ++ nativeCheckInputs;
      buildPhase = ''
        ${c.goEnv}
        ${testEnv}
        go test ${raceFlag} ${skipFlag} ./...
      '';
      installPhase = "touch $out";
    };

  goLint =
    args:
    let c = mkCtx args; in
    c.pkgs.stdenv.mkDerivation {
      name = "${c.pname}-golangci-lint";
      src = c.goSrc;
      nativeBuildInputs = [ c.goPkg c.pkgs.golangci-lint ];
      buildPhase = ''
        ${c.goEnv}
        export GOLANGCI_LINT_CACHE=$TMPDIR/golangci
        golangci-lint run ./...
      '';
      installPhase = "touch $out";
    };

  # fmtExclude: dirs/files to skip (generated code, vendored deploy configs, …).
  goFormat =
    { pkgs, root, fmtExclude ? [ ], ... }:
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
    (treefmtFor pkgs).config.build.check fmtSrc;

  formatter = { pkgs, ... }: (treefmtFor pkgs).config.build.wrapper;
}
