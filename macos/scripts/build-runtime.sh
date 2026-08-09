#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

cd "$PROJECT_DIR"
if [ ! -x configure ] || [ Makefile.am -nt configure ] || \
        ! grep -q 'ac_unique_file="src/main.cpp"' configure; then
    ./bootstrap
fi
if [ ! -f .build/fsuae-3/Makefile ] || \
        [ configure -nt .build/fsuae-3/Makefile ]; then
    mkdir -p .build/fsuae-3
    (cd .build/fsuae-3 && ../../configure \
        CXXFLAGS='-std=gnu++14 -Wno-c++11-narrowing')
fi

make -C .build/fsuae-3 libfsuaemac.dylib \
    CXXFLAGS='-std=gnu++14 -Wno-c++11-narrowing'
echo "$PROJECT_DIR/.build/fsuae-3/libfsuaemac.dylib"
