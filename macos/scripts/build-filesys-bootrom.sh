#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
VASM=${VASM:-vasmm68k_mot}
VLINK=${VLINK:-vlink}
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fsuae-filesys.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT

"$VASM" -Fhunk -no-opt -quiet -o "$BUILD_DIR/filesys.o" "$ROOT_DIR/src/filesys.asm"
"$VLINK" -bamigahunk -s -o "$BUILD_DIR/filesys" "$BUILD_DIR/filesys.o"
xxd -p -c 8 -s 32 "$BUILD_DIR/filesys" |
    sed -E 's/([0-9a-f]{2})/db(0x\1); /g; s/^/ /' > "$ROOT_DIR/src/filesys_bootrom.cpp"
