#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
VBCC=${VBCC:-"$HOME/amiga-cc/vbcc"}
OUTPUT_DIR="$ROOT_DIR/.build/amiga"

mkdir -p "$OUTPUT_DIR"
PATH="$VBCC/bin:$PATH" VBCC="$VBCC" \
    vc +kick13 -cpu=68000 -c99 \
    "$ROOT_DIR/macos/amiga/FSUAE-Diag.c" -lamiga -lauto \
    -o "$OUTPUT_DIR/FSUAE-Diag"

test -s "$OUTPUT_DIR/FSUAE-Diag"
echo "$OUTPUT_DIR/FSUAE-Diag"
