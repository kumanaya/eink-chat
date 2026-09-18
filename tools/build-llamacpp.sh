#!/bin/sh
# Cross-compiles llama.cpp for the Kindle (ARMv7, hard-float, musl, static).
#
# This is the chat runtime. llama2.c cannot run an instruct model: its tokenizer
# format is SentencePiece while every small instruct model uses BPE, and 135M in
# fp32 does not fit in the Kindle's 512 MB. llama.cpp handles GGUF, quantized
# kernels and the tokenizer, and its integer kernels use NEON -- which matters
# here, because LLVM disables NEON for floating point on this CPU's target.
#
# Runs inside WSL/Linux. Nothing is installed system-wide: Zig, CMake and Ninja
# are fetched as portable builds into ~/tc, so no sudo is needed.
#
# Usage:
#   sh tools/build-llamacpp.sh              # builds llama-completion
#   sh tools/build-llamacpp.sh --server     # builds llama-server (chat-ui's backend)
#   sh tools/build-llamacpp.sh --host       # same source, for this machine, to
#                                           # try flags and prompts locally
#
# Output: out/llama-completion or out/llama-server (ARM), or
#         out/<name>-x86 for --host.
#
# It takes a while: the source is large and this is a full C++ build.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC="$HOME/tc"
SRC="$HOME/llama.cpp"

MODE=completion
case "${1:-}" in
    --host) MODE=host ;;
    --server) MODE=server ;;
esac

if [ "$MODE" = "host" ]; then
    BUILD="$HOME/llama-build-x86"
    ZIG_TARGET=x86_64-linux-musl
    OUT_NAME=llama-completion-x86
    BUILD_SERVER=OFF
    TARGET=llama-completion
elif [ "$MODE" = "server" ]; then
    BUILD="$HOME/llama-build-server"
    ZIG_TARGET=arm-linux-musleabihf
    OUT_NAME=llama-server
    BUILD_SERVER=ON
    TARGET=llama-server
else
    BUILD="$HOME/llama-build"
    ZIG_TARGET=arm-linux-musleabihf
    OUT_NAME=llama-completion
    BUILD_SERVER=OFF
    TARGET=llama-completion
fi

# --- 1. portable toolchain ---------------------------------------------------

get() { # get <url> <dest>
    [ -s "$2" ] && return 0
    echo "  fetching $(basename "$2")"
    curl -fsSL -o "$2.part" "$1" && mv "$2.part" "$2"
}

echo "=== toolchain (into $TC) ==="
mkdir -p "$TC/bin" "$TC/dl"

if [ ! -x "$TC/zig/zig" ]; then
    get https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz "$TC/dl/zig.tar.xz"
    mkdir -p "$TC/dl/zig" && tar xJf "$TC/dl/zig.tar.xz" -C "$TC/dl/zig" --strip-components=1
    mv "$TC/dl/zig" "$TC/zig"
fi
echo "  zig   $("$TC/zig/zig" version)"

if [ ! -x "$TC/cmake/bin/cmake" ]; then
    VER=$(curl -fsSL https://api.github.com/repos/Kitware/CMake/releases/latest \
          | grep -o '"tag_name": *"v[^"]*"' | head -1 | sed 's/.*"v//;s/"//')
    get "https://github.com/Kitware/CMake/releases/download/v$VER/cmake-$VER-linux-x86_64.tar.gz" "$TC/dl/cmake.tar.gz"
    mkdir -p "$TC/dl/cmake" && tar xzf "$TC/dl/cmake.tar.gz" -C "$TC/dl/cmake" --strip-components=1
    mv "$TC/dl/cmake" "$TC/cmake"
fi
echo "  cmake $("$TC/cmake/bin/cmake" --version | head -1 | awk '{print $3}')"

if [ ! -x "$TC/ninja/ninja" ]; then
    VER=$(curl -fsSL https://api.github.com/repos/ninja-build/ninja/releases/latest \
          | grep -o '"tag_name": *"v[^"]*"' | head -1 | sed 's/.*"v//;s/"//')
    get "https://github.com/ninja-build/ninja/releases/download/v$VER/ninja-linux.zip" "$TC/dl/ninja.zip"
    # no unzip on a bare WSL, and python3 always is there
    mkdir -p "$TC/ninja" && python3 -c "import zipfile;zipfile.ZipFile('$TC/dl/ninja.zip').extractall('$TC/ninja')"
    chmod +x "$TC/ninja/ninja"
fi
echo "  ninja $("$TC/ninja/ninja" --version)"

# --- 2. source ---------------------------------------------------------------

if [ ! -d "$SRC" ]; then
    echo "=== cloning llama.cpp ==="
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$SRC"
fi
echo "=== llama.cpp $(cd "$SRC" && git log --oneline -1 | cut -c1-40) ==="

# --- 3. compiler wrappers and CMake toolchain --------------------------------

cat > "$TC/bin/${OUT_NAME}-cc" <<EOF
#!/bin/sh
exec "$TC/zig/zig" cc -target $ZIG_TARGET "\$@"
EOF
cat > "$TC/bin/${OUT_NAME}-cxx" <<EOF
#!/bin/sh
exec "$TC/zig/zig" c++ -target $ZIG_TARGET "\$@"
EOF
chmod +x "$TC/bin/${OUT_NAME}-cc" "$TC/bin/${OUT_NAME}-cxx"

cat > "$TC/${OUT_NAME}-toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR $([ "$MODE" = "host" ] && echo x86_64 || echo arm))
set(CMAKE_C_COMPILER   $TC/bin/${OUT_NAME}-cc)
set(CMAKE_CXX_COMPILER $TC/bin/${OUT_NAME}-cxx)
# Cross-compiling: do not try to link the compiler-detection tests.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF

# --- 4. configure and build --------------------------------------------------

echo "=== configuring ==="
rm -rf "$BUILD"
"$TC/cmake/bin/cmake" -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TC/${OUT_NAME}-toolchain.cmake" \
    -DCMAKE_MAKE_PROGRAM="$TC/ninja/ninja" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXE_LINKER_FLAGS="-s" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_CPU_KLEIDIAI=OFF \
    -DGGML_LLAMAFILE=OFF \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=$BUILD_SERVER \
    -DLLAMA_BUILD_TOOLS=ON > "$TC/configure.log" 2>&1 || {
        echo "configure failed; last lines:"; tail -20 "$TC/configure.log"; exit 1
    }

# GGML_LLAMAFILE=OFF is not optional on ARMv7: its sgemm uses fp16 intrinsics
# (vld1q_f16) that a Cortex-A9 does not have, and the build stops there.
#
# Only the one target: the umbrella "llama" app also wants the server, which is
# disabled, so it cannot link. llama-completion is the CLI we actually call.

echo "=== building $TARGET (this takes a while) ==="
cd "$BUILD"
if ! "$TC/ninja/ninja" "$TARGET" > "$TC/build.log" 2>&1; then
    echo "build failed; errors:"
    grep -E '^FAILED|error:' "$TC/build.log" | head -15
    exit 1
fi

mkdir -p "$ROOT/out"
cp "$BUILD/bin/$TARGET" "$ROOT/out/$OUT_NAME"
echo
echo "=== built ==="
ls -l "$ROOT/out/$OUT_NAME" | awk '{printf "  %s  %.1f MB\n", $9, $5/1024/1024}'

if [ "$MODE" != "host" ]; then
    echo
    echo "=== ELF check ==="
    python3 "$ROOT/tools/inspect-elf.py" "$ROOT/out/$OUT_NAME" || true
fi
