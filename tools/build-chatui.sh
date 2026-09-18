#!/bin/sh
# Builds chat-ui, the GTK chat window.
#
#   sh tools/build-chatui.sh          # for this machine -> out/chat-ui
#   sh tools/build-chatui.sh --kindle # cross-compiled   -> out/chat-ui-kindle
#
# Host: GTK 3 development files (pkg-config gtk+-3.0) and a C compiler.
# Kindle: koxtoolchain with GTK3 in the sysroot. Point KOX_TC at the toolchain
# prefix (default: ~/x-tools/arm-kindlehf) or set CC/PKG_CONFIG_* yourself.
#
# Only the resulting executable goes to the device; nothing here is needed on
# the Kindle.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/chat-ui.c"
OUT="$ROOT/out"
mkdir -p "$OUT"

if [ "${1:-}" = "--kindle" ]; then
    TC="${KOX_TC:-$HOME/x-tools/arm-kindlehf-linux-gnueabihf}"
    if [ -z "${CC:-}" ]; then
        CC="$TC/bin/arm-kindlehf-linux-gnueabihf-gcc"
    fi
    if [ ! -x "$CC" ]; then
        echo "error: no ARM cross compiler ($CC)" >&2
        echo "  build koxtoolchain and install kindlehf first:" >&2
        echo "    git clone --recursive --depth 1 https://github.com/koreader/koxtoolchain.git" >&2
        echo "    cd koxtoolchain && ./gen-tc.sh kindlehf" >&2
        echo "  then install the Kindle SDK, which brings GTK 2 into the sysroot:" >&2
        echo "    git clone --recursive --depth 1 https://github.com/KindleModding/kindle-sdk.git" >&2
        echo "    cd kindle-sdk && ./gen-sdk.sh kindlehf" >&2
        echo "  then: KOX_TC=$TC sh tools/build-chatui.sh --kindle" >&2
        exit 1
    fi
    SYSROOT="${SYSROOT:-$TC/arm-kindlehf-linux-gnueabihf/sysroot}"
    export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
    export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
    # The Kindle SDK ships GTK 2 only; chat-ui.c builds against either.
    if ! pkg-config --exists gtk+-2.0; then
        echo "error: gtk+-2.0 is not in the sysroot" >&2
        echo "  install the Kindle SDK: cd kindle-sdk && ./gen-sdk.sh kindlehf" >&2
        exit 1
    fi
    # shellcheck disable=SC2046
    "$CC" --sysroot "$SYSROOT" -O2 -Wall -Wextra -s \
        $(pkg-config --cflags gtk+-2.0) -o "$OUT/chat-ui-kindle" "$SRC" \
        $(pkg-config --libs gtk+-2.0)
    echo "  built out/chat-ui-kindle ($(du -h "$OUT/chat-ui-kindle" | cut -f1), GTK 2)"
    exit 0
fi

if [ -z "${CC:-}" ]; then
    if command -v cc >/dev/null 2>&1; then
        CC=cc
    elif command -v zig >/dev/null 2>&1; then
        CC="zig cc"
    else
        echo "error: no C compiler (cc or zig)" >&2
        exit 1
    fi
fi
if ! command -v pkg-config >/dev/null 2>&1; then
    echo "error: pkg-config not found" >&2
    exit 1
fi
if ! pkg-config --exists gtk+-3.0; then
    echo "error: GTK 3 development files not found" >&2
    echo "  Arch:   sudo pacman -S gtk3" >&2
    echo "  Debian: sudo apt install libgtk-3-dev" >&2
    exit 1
fi

# shellcheck disable=SC2086
$CC -O2 -Wall -Wextra $(pkg-config --cflags gtk+-3.0) -o "$OUT/chat-ui" "$SRC" \
    $(pkg-config --libs gtk+-3.0)
echo "  built out/chat-ui ($(du -h "$OUT/chat-ui" | cut -f1))"
