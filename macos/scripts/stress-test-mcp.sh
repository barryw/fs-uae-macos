#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

cd "$PROJECT_DIR"
exec swift run --package-path macos/MacFSUAEKit "FS-UAE Stress" "$@"
