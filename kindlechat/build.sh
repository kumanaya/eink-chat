#!/bin/sh
# Build llama2.c for the Kindle, or for the PC (to validate the pipeline).
#
# Usage:
#   ./build.sh                     # default: zig-arm (Windows/Linux, no toolchain)
#   TARGET=host ./build.sh         # runs on the PC, no cross-compiling
#   TARGET=kindlehf ./build.sh     # koxtoolchain/glibc (FW >= 5.16.3)
#   SRC=runq.c ./build.sh          # quantized Q8_0 runner -> out/llama-q8
#
# Output: out/llama (or out/llama-q8 for runq.c)
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"
OUT="$ROOT/out"

TARGET="${TARGET:-zig-arm}"
SRC="${SRC:-run.c}"

# Optimization flags. If the binary dies with "Illegal instruction" on the
# device, rebuild with ARCH_FLAGS="" to get a generic binary.
ARCH_FLAGS="${ARCH_FLAGS:--O3 -funroll-loops}"

# run.c uses int8_t without including <stdint.h>: on glibc that works by accident
# (it pulls stdint in via another header), on musl it does not. Forcing the
# include fixes both.
PREINCLUDE="-include stdint.h"

case "$SRC" in
    run.c)  OUT_NAME="llama" ;;
    runq.c) OUT_NAME="llama-q8" ;;
    *)      OUT_NAME="$(basename "$SRC" .c)" ;;
esac

if [ ! -f "$VENDOR/$SRC" ]; then
    echo "error: $VENDOR/$SRC does not exist (run tools/fetch.sh)" >&2
    exit 1
fi

case "$TARGET" in
    host)
        if [ -z "$CC" ]; then
            CC="$(command -v gcc 2>/dev/null || command -v cc 2>/dev/null || true)"
        fi
        if [ -z "$CC" ]; then
            echo "error: no C compiler found (install gcc, or use TARGET=zig-arm)" >&2
            exit 1
        fi
        EXTRA_FLAGS="$PREINCLUDE"
        LINK_EXTRA=""
        ;;

    zig-arm)
        # Cross-compile ARMv7 hard-float, statically linked against musl.
        # Works on Windows and Linux, with no toolchain to install.
        if [ -n "$ZIG" ]; then
            ZIG_BIN="$ZIG"
        else
            ZIG_BIN="$(command -v zig 2>/dev/null || true)"
        fi
        if [ -z "$ZIG_BIN" ]; then
            cat >&2 <<'EOF'
error: 'zig' not found.

Install it (pick one):
  winget install zig.zig                        (Windows)
  choco install zig                             (Windows)
  apt-get install zig                           (or download from ziglang.org/download)

Or point at it explicitly:  ZIG=/path/to/zig ./build.sh
EOF
            exit 1
        fi
        CC="$ZIG_BIN"
        ZIG_TARGET="arm-linux-musleabihf"
        EXTRA_FLAGS="$PREINCLUDE"
        LINK_EXTRA="-static"
        ;;

    kindlehf|kindlepw2|kindle5)
        case "$TARGET" in
            kindlehf)  PREFIX="arm-kindlehf-linux-gnueabihf" ;;
            kindlepw2) PREFIX="arm-kindlepw2-linux-gnueabi" ;;
            kindle5)   PREFIX="arm-kindle5-linux-gnueabi" ;;
        esac
        CC="${CROSS_COMPILE:-$HOME/x-tools/$PREFIX/bin/$PREFIX-gcc}"
        if [ ! -x "$CC" ] && ! command -v "$CC" >/dev/null 2>&1; then
            echo "error: compiler not found: $CC" >&2
            cat >&2 <<EOF

Prefer TARGET=zig-arm, which needs no toolchain.
If you really want the glibc toolchain (once, ~30 min):

  sudo apt-get install -y build-essential autoconf automake bison flex gawk \\
      libtool libtool-bin libncurses-dev curl file git gperf help2man \\
      texinfo unzip wget
  git clone --recursive --depth 1 https://github.com/koreader/koxtoolchain.git
  cd koxtoolchain && chmod +x gen-tc.sh && ./gen-tc.sh $TARGET

The toolchain lands in ~/x-tools/$PREFIX/
EOF
            exit 1
        fi
        EXTRA_FLAGS="$PREINCLUDE"
        LINK_EXTRA="-static"
        ;;

    *)
        echo "error: invalid TARGET: $TARGET" >&2
        echo "valid: host, zig-arm, kindlehf, kindlepw2, kindle5" >&2
        exit 1
        ;;
esac

mkdir -p "$OUT"
echo "target    : $TARGET"
echo "source    : vendor/$SRC"
echo "output    : out/$OUT_NAME"
echo "compiler  : $CC"
echo "flags     : $ARCH_FLAGS $EXTRA_FLAGS $LINK_EXTRA"
echo

# shellcheck disable=SC2086
if [ "$TARGET" = "zig-arm" ]; then
    "$CC" cc -target "$ZIG_TARGET" $ARCH_FLAGS $EXTRA_FLAGS $LINK_EXTRA \
        -o "$OUT/$OUT_NAME" "$VENDOR/$SRC" -lm
else
    "$CC" $ARCH_FLAGS $EXTRA_FLAGS $LINK_EXTRA -o "$OUT/$OUT_NAME" "$VENDOR/$SRC" -lm
fi

echo
ls -lh "$OUT/$OUT_NAME"
echo

# ELF check (for ARM targets): confirms hard-float and self-contained.
if [ "$TARGET" != "host" ] && command -v python3 >/dev/null 2>&1; then
    if [ -f "$ROOT/tools/inspect-elf.py" ]; then
        python3 "$ROOT/tools/inspect-elf.py" "$OUT/$OUT_NAME" || true
    fi
fi
