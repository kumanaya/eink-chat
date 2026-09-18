#!/bin/sh
# Downloads the MVP dependencies (llama2.c + the TinyStories 15M model).
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
MODEL="$ROOT/model"
mkdir -p "$VENDOR" "$MODEL"

LLAMA2C="https://raw.githubusercontent.com/karpathy/llama2.c/master"
TINYLLAMAS="https://huggingface.co/karpathy/tinyllamas/resolve/main"

fetch() {
    url="$1"
    dest="$2"
    if [ -s "$dest" ]; then
        echo "already there: $dest"
        return 0
    fi
    echo "downloading: $url"
    curl -fL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
    echo "ok: $dest ($(wc -c < "$dest") bytes)"
}

fetch "$LLAMA2C/run.c"          "$VENDOR/run.c"
fetch "$LLAMA2C/runq.c"         "$VENDOR/runq.c"
fetch "$LLAMA2C/tokenizer.bin"  "$VENDOR/tokenizer.bin"
fetch "$TINYLLAMAS/stories15M.bin" "$MODEL/stories15M.bin"

# The instruct model is what makes this answer questions instead of continuing
# stories. It is ~101 MB, so it is opt-in.
if [ "${WITH_CHAT:-0}" = "1" ]; then
    fetch "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf" \
          "$MODEL/SmolLM2-135M-Instruct-Q4_K_M.gguf"
else
    echo
    echo "chat model skipped. For a chat that answers, re-run with:"
    echo "    WITH_CHAT=1 sh tools/fetch.sh"
fi

echo
echo "=== summary ==="
ls -lh "$VENDOR" "$MODEL"
