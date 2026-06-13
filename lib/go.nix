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
    , embedDirs ? [ ]
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
          ] ++ map fs.maybeMissing embedDirs))
          (fs.maybeMissing (root + "/vendor"));
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

  goTest =
    { goSkip ? [ ], goRace ? false, ... }@args:
    let
      c = mkCtx args;
      raceFlag = c.lib.optionalString goRace "-race";
      skipFlag = c.lib.optionalString (goSkip != [ ]) "-skip '${c.lib.concatStringsSep "|" goSkip}'";
    in
    c.pkgs.stdenv.mkDerivation {
      name = "${c.pname}-gotest";
      src = c.goSrc;
      nativeBuildInputs = [ c.goPkg ];
      buildPhase = ''
        ${c.goEnv}
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

  goFormat =
    { pkgs, root, ... }:
    let
      fs = pkgs.lib.fileset;
      fmtSrc = fs.toSource {
        inherit root;
        fileset = fs.unions [
          (root + "/go.mod")
          (fs.fileFilter (f: f.hasExt "go") root)
          (fs.fileFilter (f: f.hasExt "nix") root)
        ];
      };
    in
    (treefmtFor pkgs).config.build.check fmtSrc;

  formatter = { pkgs, ... }: (treefmtFor pkgs).config.build.wrapper;
}
