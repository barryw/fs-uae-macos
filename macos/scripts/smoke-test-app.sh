#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
APP=${1:-"$ROOT_DIR/.build/macos/FS-UAE Mac.app"}
CONFIGURATION=${2:-"$HOME/Documents/FS-UAE/Configurations/A500.fs-uae"}
LOG=$(mktemp "${TMPDIR:-/tmp}/fsuaemac-app-smoke.XXXXXX")
trap 'rm -f "$LOG"' EXIT

for SOUND in drive_click drive_spin drive_spinnd drive_startup drive_snatch; do
    test -f "$APP/Contents/Resources/fs-uae/floppy_sounds/$SOUND.wav"
done
test -s "$APP/Contents/Resources/Amiga/FSUAE-Diag"

if FSUAE_MAC_SMOKE_CONFIGURATION="$CONFIGURATION" \
        "$APP/Contents/MacOS/FS-UAE Mac" --fsuae-mac-smoke-test >"$LOG" 2>&1; then
    grep 'FS-UAE Mac app smoke test passed' "$LOG"
else
    cat "$LOG" >&2
    exit 1
fi
