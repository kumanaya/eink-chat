#!/bin/sh
# Tests for the plugin's run-model.sh runner.
#
# The runner is the boundary between the plugin and the model binary, and it is
# plain shell, so it can be exercised on the PC with a stub "llama".
#
# Usage:
#   sh tests/test-run-model.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/run-model.sh"
WORK="${TMPDIR:-/tmp}/kindlechat-runner-test.$$"
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

check() {
    if eval "$2" >/dev/null 2>&1; then
        printf '  ok       %s\n' "$1"
    else
        printf '  FAILED   %s\n' "$1"
        FAIL=1
    fi
}

echo "=== run-model.sh ==="
echo

# --- a fake APP_DIR with a stub binary --------------------------------------

APP="$WORK/app"
mkdir -p "$APP/model"

cat > "$APP/llama" <<'STUB'
#!/bin/sh
# Registers the arguments it received, then pretends to generate.
i=0
for a in "$@"; do
    i=$((i + 1))
    echo "[stub] arg$i=[$a]" >&2
done
echo "Once upon a time, there was a little robot."
echo "achieved tok/s: 42.5" >&2
STUB
chmod +x "$APP/llama"
: > "$APP/model/stories15M.bin"
: > "$APP/model/tokenizer.bin"

PROMPT="$WORK/prompt.txt"
OUT="$WORK/out.txt"

# --- 1. normal run ----------------------------------------------------------

echo "--- 1. normal run ---"
printf 'Once upon a time, there was a robot with "quotes" and $dollars; rm -rf /' > "$PROMPT"
APP_DIR="$APP" sh "$RUNNER" "$PROMPT" "$OUT" 60 0.8 0.9
echo "  exit code: $?"

check "output has the model text"        "grep -q 'little robot' '$OUT'"
check "output ends with the DONE mark"   "grep -q '__KINDLE_CHAT_DONE__ 42.5' '$OUT'"
check "no ERROR mark"                    "! grep -q '__KINDLE_CHAT_ERROR__' '$OUT'"
check "steps reached the binary"         "grep -q 'arg9=\[60\]' '$OUT.err'"
check "temp reached the binary"          "grep -q 'arg5=\[0.8\]' '$OUT.err'"
check "top-p reached the binary"         "grep -q 'arg7=\[0.9\]' '$OUT.err'"
check "model passed as argument 1"       "grep -q 'arg1=\[$APP/model/stories15M.bin\]' '$OUT.err'"
check "tokenizer passed via -z"          "grep -q 'arg3=\[$APP/model/tokenizer.bin\]' '$OUT.err'"

echo
echo "  --- what the stub received ---"
grep -o '\[stub\] arg[0-9]*=\[.*\]' "$OUT.err" | sed 's/^/      /'

# The prompt contains shell metacharacters on purpose: it must arrive intact and
# as a single argument.
check "prompt arrived intact (1 argument)" \
    "grep -q 'arg11=\[Once upon a time, there was a robot with \"quotes\" and \$dollars; rm -rf /\]' '$OUT.err'"
echo

# --- 2. missing prompt file -------------------------------------------------

echo "--- 2. missing prompt file ---"
OUT2="$WORK/out2.txt"
APP_DIR="$APP" sh "$RUNNER" "$WORK/nope.txt" "$OUT2" 60 0.8 0.9
echo "  exit code: $?"
check "reported an error"                "grep -q '__KINDLE_CHAT_ERROR__' '$OUT2'"
check "named the missing prompt"         "grep -q 'prompt file' '$OUT2'"
echo

# --- 3. no runner at all ----------------------------------------------------

echo "--- 3. no runner binary ---"
EMPTY="$WORK/empty"
mkdir -p "$EMPTY/model"
: > "$EMPTY/model/tokenizer.bin"
OUT3="$WORK/out3.txt"
APP_DIR="$EMPTY" sh "$RUNNER" "$PROMPT" "$OUT3" 60 0.8 0.9
echo "  exit code: $?"
check "reported an error"                "grep -q '__KINDLE_CHAT_ERROR__' '$OUT3'"
check "said no runner was found"         "grep -q 'no runner' '$OUT3'"
echo

# --- 4. missing model -------------------------------------------------------

echo "--- 4. runner present but model missing ---"
NOMODEL="$WORK/nomodel"
mkdir -p "$NOMODEL/model"
cp "$APP/llama" "$NOMODEL/llama"
: > "$NOMODEL/model/tokenizer.bin"
OUT4="$WORK/out4.txt"
APP_DIR="$NOMODEL" sh "$RUNNER" "$PROMPT" "$OUT4" 60 0.8 0.9
echo "  exit code: $?"
check "reported an error"                "grep -q '__KINDLE_CHAT_ERROR__' '$OUT4'"
check "named the missing model"          "grep -q 'model' '$OUT4'"
echo

# --- 5. usage ---------------------------------------------------------------

echo "--- 5. no arguments ---"
sh "$RUNNER" 2>/dev/null
echo "  exit code: $? (expected 2)"
check "usage exit code is 2"             "[ \"\$?\" = \"2\" ] || sh '$RUNNER' >/dev/null 2>&1; [ \$? -eq 2 ]"
echo

# --- 6. chat mode: llama.cpp with a .gguf ------------------------------------
# The probe covers this end to end inside KOReader, but that harness downloads
# KOReader; this keeps a fast check on the branch itself.

echo "--- 6. chat mode (llama-completion + a .gguf) ---"
CHAT="$WORK/chat"
mkdir -p "$CHAT/model"
cat > "$CHAT/llama-completion" <<'STUB'
#!/bin/sh
# records the prompt it was handed, and answers like llama.cpp would
prev=""
for a in "$@"; do
    if [ "$prev" = "-p" ]; then printf '%s' "$a" > "$APP_DIR/last-prompt.txt"; fi
    prev="$a"
done
echo "The capital of France is Paris. [end of text]"
echo "common_perf_print: eval time = 100 ms / 10 runs ( 10.00 ms per token, 42.50 tokens per second)" >&2
STUB
chmod +x "$CHAT/llama-completion"
: > "$CHAT/model/stub.q4_k_m.gguf"
: > "$CHAT/model/tokenizer.bin"

printf '<|im_start|>user\nWhat is the capital of France?<|im_end|>\n<|im_start|>assistant\n' > "$CHAT/prompt.txt"
OUT6="$WORK/out6.txt"
APP_DIR="$CHAT" sh "$RUNNER" "$CHAT/prompt.txt" "$OUT6" 30 0.3 0.9
echo "  exit code: $?"

check "the gguf was auto-detected and ran"   "grep -q 'Paris' '$OUT6'"
check "the ChatML prompt reached the binary" "grep -q 'im_start' '$CHAT/last-prompt.txt'"
check "the EOS marker was stripped"          "! grep -q 'end of text' '$OUT6'"
check "llama.cpp tok/s was parsed"           "grep -q '__KINDLE_CHAT_DONE__ 42.50' '$OUT6'"
check "no ERROR mark"                        "! grep -q '__KINDLE_CHAT_ERROR__' '$OUT6'"
echo

# --- 7. chat mode with a runner that is not executable -----------------------
# /mnt/us is sometimes mounted without the execute bit; the runner must fix it
# or say so, never return an empty answer silently.

echo "--- 7. chat runner without the execute bit ---"
CHAT7="$WORK/chat7"
mkdir -p "$CHAT7/model"
cp "$CHAT/llama-completion" "$CHAT7/llama-completion"
chmod -x "$CHAT7/llama-completion"
: > "$CHAT7/model/stub.q4_k_m.gguf"
OUT7="$WORK/out7.txt"
APP_DIR="$CHAT7" sh "$RUNNER" "$CHAT/prompt.txt" "$OUT7" 20 0.3 0.9
echo "  exit code: $?"
check "it recovered by chmod +x"             "grep -q 'Paris' '$OUT7'"
check "no ERROR mark"                        "! grep -q '__KINDLE_CHAT_ERROR__' '$OUT7'"
echo

if [ "$FAIL" = "0" ]; then
    echo "RESULT: all good"
else
    echo "RESULT: something failed"
fi
exit $FAIL
