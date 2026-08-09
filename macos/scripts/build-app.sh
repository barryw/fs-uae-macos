#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PACKAGE_DIR="$ROOT_DIR/macos/MacFSUAEKit"
APP="$ROOT_DIR/.build/macos/FS-UAE Mac.app"
CONTENTS="$APP/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"

is_system_dependency() {
    case "$1" in
        /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) return 0 ;;
        *) return 1 ;;
    esac
}

dependencies() {
    otool -L "$1" | sed '1d; s/^[[:space:]]*//; s/[[:space:]]*(.*//'
}

bundle_dependencies() {
    local binary="$1" dependency name bundled
    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        is_system_dependency "$dependency" && continue
        [[ -f "$dependency" ]] || { echo "Missing dependency: $dependency" >&2; exit 1; }
        name=$(basename "$dependency")
        [[ "$name" == "$(basename "$binary")" ]] && continue
        bundled="$FRAMEWORKS/$name"
        if [[ ! -f "$bundled" ]]; then
            cp "$dependency" "$bundled"
            chmod u+w "$bundled"
            install_name_tool -id "@rpath/$name" "$bundled"
            bundle_dependencies "$bundled"
        fi
        install_name_tool -change "$dependency" "@loader_path/$name" "$binary"
    done < <(dependencies "$binary")
}

"$ROOT_DIR/macos/scripts/build-runtime.sh"
"$ROOT_DIR/macos/scripts/build-amiga-tools.sh"
SWIFT_MODULECACHE_PATH=/tmp/fsuae-swift-cache \
CLANG_MODULE_CACHE_PATH=/tmp/fsuae-clang-cache \
    swift build --package-path "$PACKAGE_DIR" -c release --disable-sandbox
BIN_DIR=$(SWIFT_MODULECACHE_PATH=/tmp/fsuae-swift-cache \
    CLANG_MODULE_CACHE_PATH=/tmp/fsuae-clang-cache \
    swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path --disable-sandbox)

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$FRAMEWORKS" "$CONTENTS/Resources"
cp "$BIN_DIR/FS-UAE Mac" "$CONTENTS/MacOS/FS-UAE Mac"
cp "$BIN_DIR/FS-UAE Worker" "$CONTENTS/MacOS/FS-UAE Worker"
cp "$ROOT_DIR/.build/fsuae-3/libfsuaemac.dylib" "$FRAMEWORKS/libfsuaemac.dylib"
cp "$ROOT_DIR/macos/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/dist/macos/fs-uae.icns" "$CONTENTS/Resources/fs-uae.icns"
mkdir -p "$CONTENTS/Resources/fs-uae"
cp -R "$ROOT_DIR/share/fs-uae/floppy_sounds" "$CONTENTS/Resources/fs-uae/"
mkdir -p "$CONTENTS/Resources/Amiga"
cp "$ROOT_DIR/.build/amiga/FSUAE-Diag" "$CONTENTS/Resources/Amiga/FSUAE-Diag"

chmod u+w "$FRAMEWORKS/libfsuaemac.dylib"
install_name_tool -id "@rpath/libfsuaemac.dylib" "$FRAMEWORKS/libfsuaemac.dylib"
bundle_dependencies "$FRAMEWORKS/libfsuaemac.dylib"

for binary in "$FRAMEWORKS"/*; do
    if dependencies "$binary" | grep -q '^/opt/homebrew/'; then
        echo "Unbundled Homebrew dependency in $binary" >&2
        exit 1
    fi
    codesign --force --sign - --timestamp=none "$binary"
done
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP"
