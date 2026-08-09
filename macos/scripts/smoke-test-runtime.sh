#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
RUNTIME=${1:-"$ROOT_DIR/.build/fsuae-3/libfsuaemac.dylib"}
CONFIGURATION=${2:-"$HOME/Documents/FS-UAE/Configurations/A500.fs-uae"}
SMOKE="$ROOT_DIR/.build/fsuae-3/fsuaemac-runtime-smoke"
LOG=$(mktemp "${TMPDIR:-/tmp}/fsuaemac-smoke.XXXXXX")
trap 'rm -f "$LOG"' EXIT

clang -std=c11 -I"$ROOT_DIR/macos/include" \
    "$ROOT_DIR/macos/tests/runtime-smoke.c" -o "$SMOKE"
if "$SMOKE" "$RUNTIME" "$CONFIGURATION" >"$LOG" 2>&1; then
    tail -n 1 "$LOG"
else
    cat "$LOG" >&2
    exit 1
fi
