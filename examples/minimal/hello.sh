#!/usr/bin/env bash
# Fixture for the fileset/escape-hatch knobs: `sh` is an extension goFormat
# does not include by default, and shfmt is a program flake-checks does not
# enable by default. `fmtExts = [ "sh" ]` puts this file in the check's source
# and `treefmtExtra` turns shfmt on, so CI fails if either knob regresses.
set -euo pipefail

echo "hello from a formatted shell script"
