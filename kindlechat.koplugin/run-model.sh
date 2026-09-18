#!/bin/sh
# Non-interactive model runner, used by the kindlechat KOReader plugin.
#
# Usage: run-model.sh <prompt_file> <out_file> [steps] [temp] [top_p]
#
# Writes the generated text into <out_file> and finishes with a sentinel line so
# the caller can tell generation is complete and read the throughput:
#
#     __KINDLE_CHAT_DONE__ <tok/s>
#
# On a broken environment it writes "__KINDLE_CHAT_ERROR__ <reason>" instead.
#
# Two runtimes, picked by what is installed:
#
#   llama.cpp (llama-completion + a .gguf)  -> a real instruct model: it answers
#   llama2.c  (llama + a .bin)              -> the TinyStories base model
#
# The prompt is read from a file and never placed on the command line, so the
# user's text is never parsed by a shell.

APP_DIR="${APP_DIR:-/mnt/us/extensions/kindlechat}"
CFG="$APP_DIR/chat.conf"

# These may be overridden from the environment, which is also how the tests
# point the runner at a host build.
LLAMA_CPP="${LLAMA_CPP:-$APP_DIR/llama-completion}"
GGUF="${GGUF:-}"
LLAMA2C="${LLAMA2C:-$APP_DIR/llama}"
LLAMA2C_MODEL="${LLAMA2C_MODEL:-$APP_DIR/model/stories15M.bin}"
TOKENIZER="${TOKENIZER:-$APP_DIR/model/tokenizer.bin}"

PROMPT_FILE="$1"
OUT_FILE="$2"
STEPS="${3:-60}"
TEMP="${4:-0.8}"
TOPP="${5:-0.9}"

DONE_MARK="__KINDLE_CHAT_DONE__"
ERROR_MARK="__KINDLE_CHAT_ERROR__"

fail() {
    printf '%s %s\n' "$ERROR_MARK" "$1" >> "$OUT_FILE"
    exit 1
}

[ -n "$PROMPT_FILE" ] && [ -n "$OUT_FILE" ] || {
    echo "usage: run-model.sh <prompt_file> <out_file> [steps] [temp] [top_p]" >&2
    exit 2
}

[ -r "$CFG" ] && . "$CFG"

# Find a .gguf if one was not named.
if [ -z "$GGUF" ]; then
    for cand in "$APP_DIR"/model/*.gguf; do
        [ -e "$cand" ] && { GGUF="$cand"; break; }
    done
fi

: > "$OUT_FILE"
[ -r "$PROMPT_FILE" ] || fail "cannot read the prompt file: $PROMPT_FILE"

ERR="$OUT_FILE.err"
: > "$ERR"
PROMPT="$(cat "$PROMPT_FILE")"

if [ -n "$GGUF" ] && [ -e "$GGUF" ] && [ -e "$LLAMA_CPP" ]; then
    # --- instruct model through llama.cpp ---------------------------------
    # /mnt/us is sometimes mounted without the execute bit, and then the binary
    # is silently un-runnable: the turn would come back empty with no
    # explanation. Same check as the llama2.c branch below.
    [ -x "$LLAMA_CPP" ] || chmod +x "$LLAMA_CPP" 2>/dev/null
    [ -x "$LLAMA_CPP" ] || fail "llama-completion is not executable: $LLAMA_CPP (try: chmod +x)"

    # -c matters more than it looks: the model's own context is 8192, and the KV
    # cache for that is ~189 MB of the Kindle's 512 MB. 1024 is plenty for a chat
    # and costs ~24 MB.
    #
    # -no-cnv: the caller already applied the model's chat template and we want
    # plain completion. Without a template an instruct model emits end-of-text
    # straight away, which looks like "the model answered nothing".
    "$LLAMA_CPP" -m "$GGUF" -p "$PROMPT" -n "$STEPS" -c "${CTX:-1024}" \
        --temp "$TEMP" --top-p "$TOPP" -no-cnv --no-display-prompt \
        >> "$OUT_FILE" 2>"$ERR"
    STATUS=$?
else
    # --- TinyStories base model through llama2.c --------------------------
    if [ ! -e "$LLAMA2C" ]; then
        fail "no runner found: neither a .gguf with llama-completion, nor $LLAMA2C"
    fi
    [ -r "$LLAMA2C_MODEL" ] || fail "cannot read the model: $LLAMA2C_MODEL"
    [ -r "$TOKENIZER" ]     || fail "cannot read the tokenizer: $TOKENIZER"

    # /mnt/us is sometimes mounted without the execute bit, and then the binary
    # is silently un-runnable.
    [ -x "$LLAMA2C" ] || chmod +x "$LLAMA2C" 2>/dev/null
    [ -x "$LLAMA2C" ] || fail "the runner is not executable: $LLAMA2C (try: chmod +x)"

    "$LLAMA2C" "$LLAMA2C_MODEL" -z "$TOKENIZER" -t "$TEMP" -p "$TOPP" -n "$STEPS" \
        -i "$PROMPT" >> "$OUT_FILE" 2>"$ERR"
    STATUS=$?
fi

if [ "$STATUS" != "0" ] && [ ! -s "$OUT_FILE" ]; then
    fail "the runner exited with $STATUS: $(tail -2 "$ERR" | tr '\n' ' ')"
fi

# llama.cpp writes "[end of text]" where the model emitted its EOS token; in a
# chat bubble that is just noise.
if grep -q '\[end of text\]' "$OUT_FILE" 2>/dev/null; then
    sed 's/\[end of text\]//g' "$OUT_FILE" > "$OUT_FILE.clean" && mv "$OUT_FILE.clean" "$OUT_FILE"
fi

# llama.cpp prints "101.23 tokens per second"; llama2.c prints "achieved tok/s: 8.21"
TOKS="$(grep -aoE '[0-9.]+ tokens per second' "$ERR" 2>/dev/null | tail -1 | sed 's/ tokens per second//')"
if [ -z "$TOKS" ]; then
    TOKS="$(grep -o 'achieved tok/s: [0-9.]*' "$ERR" 2>/dev/null | tail -1 | sed 's/.*: //')"
fi
[ -z "$TOKS" ] && TOKS="?"

# Two numbers that only the device can answer, so the first run reports them:
# how long the weights took to come off flash (the runner starts a fresh process
# every turn, so this is paid per turn), and how much RAM was left afterwards.
LOAD_MS="$(grep -aoE 'load time = *[0-9.]+' "$ERR" 2>/dev/null | tail -1 | grep -oE '[0-9.]+$')"
LOAD_S="$(awk -v ms="${LOAD_MS:-0}" 'BEGIN { if (ms > 0) printf "%.1f", ms / 1000 }')"
MEM_MB="$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null)"

printf '\n%s %s %s %s\n' "$DONE_MARK" "$TOKS" "${LOAD_S:-?}" "${MEM_MB:-?}" >> "$OUT_FILE"
