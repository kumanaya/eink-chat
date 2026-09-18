#!/bin/sh
# Functional test for chat.sh, without a Kindle.
#
# Runs the scriptlet with a fake "llama" binary and no fbink, and checks that:
#   - the model output is captured into last.txt
#   - tok/s is extracted from stderr and shown to the user
#   - the arguments reach the binary correctly (including a prompt with spaces)
#   - the error path (missing files) builds the warning screen
#
# Usage:
#   sh tests/functional.sh
#
# For the static part (syntax, CRLF, BOM, metadata), use ../../dev-tools/check.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/kindlechat-test.$$"
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

echo "=== kindlechat: functional test (stub binary, no fbink) ==="
echo

# --- scenario 1: normal run -------------------------------------------------

APP="$WORK/app"
mkdir -p "$APP/model"

cat > "$APP/llama" <<'STUB'
#!/bin/sh
i=0
for a in "$@"; do
    i=$((i + 1))
    echo "[stub] arg$i=[$a]" >&2
done
echo "Once upon a time, there was a little robot."
echo "The robot liked to help people."
echo "One day it found a lost cat."
echo "achieved tok/s: 42.5" >&2
STUB
chmod +x "$APP/llama"

: > "$APP/model/stories15M.bin"
: > "$APP/model/tokenizer.bin"

cat > "$APP/chat.conf" <<'CONF'
PROMPT="pipeline test with spaces"
STEPS=3
MAX_WAIT=1
CONF

# timeout: after inference the script waits for a tap, which never comes here
timeout 15 env APP_DIR="$APP" sh "$ROOT/chat.sh" > "$APP/stdout.txt" 2>"$APP/stderr.txt"
rc=$?
echo "  exit code: $rc  (124 = stopped in wait_for_tap, expected with no touch)"
echo

echo "  --- on-screen output (stdout) ---"
sed 's/^/      /' "$APP/stdout.txt"
echo

check "last.txt captured the model output"   "head -1 '$APP/last.txt' | grep -q 'little robot'"
check "tok/s was extracted from stderr"      "grep -q 'tok/s: 42.5' '$APP/stdout.txt'"
check "model passed as argument 1"           "grep -q 'arg1=\[$APP/model/stories15M.bin\]' '$APP/chat.log'"
check "-z pointed at the tokenizer"          "grep -q 'arg3=\[$APP/model/tokenizer.bin\]' '$APP/chat.log'"
check "-t reflected TEMP from chat.conf"     "grep -q 'arg5=\[0.8\]' '$APP/chat.log'"
check "-n reflected STEPS from chat.conf"    "grep -q 'arg9=\[3\]' '$APP/chat.log'"
check "prompt with spaces stayed 1 argument" "grep -q 'arg11=\[pipeline test with spaces\]' '$APP/chat.log'"
check "log recorded the tok/s"               "grep -q 'tok/s: 42.5' '$APP/chat.log'"
check "with no Q8 model, picked fp32"        "grep -q 'variant=fp32' '$APP/chat.log'"
check "and ran the fp32 binary"              "grep -q 'runner: $APP/llama$' '$APP/chat.log'"

echo
echo "  --- what the binary received ---"
grep -o '\[stub\] arg[0-9]*=\[.*\]' "$APP/chat.log" | sed 's/^/      /'
echo

# --- scenario 2: missing files ----------------------------------------------

echo "--- scenario 2: empty APP_DIR (missing files) ---"
APP2="$WORK/empty"
mkdir -p "$APP2"

timeout 8 env APP_DIR="$APP2" sh "$ROOT/chat.sh" > "$APP2/out.txt" 2>&1
echo "  exit code: $?"
check "the error screen was built"        "grep -q 'E-INK HACK - ERROR' '$APP2/out.txt'"
check "the error lists the expected path" "grep -q '$APP2' '$APP2/out.txt'"
check "the log recorded the abort"        "grep -q 'aborting' '$APP2/chat.log'"
echo

# --- scenario 3: binary without the execute bit ------------------------------

echo "--- scenario 3: binary without the execute bit (/tmp fallback) ---"
APP3="$WORK/noexec"
mkdir -p "$APP3/model"
cp "$APP/llama" "$APP3/llama"
chmod -x "$APP3/llama"
: > "$APP3/model/stories15M.bin"
: > "$APP3/model/tokenizer.bin"
cat > "$APP3/chat.conf" <<'CONF'
PROMPT="no execute bit"
STEPS=3
MAX_WAIT=1
CONF

rm -f /tmp/kindlechat-llama
timeout 15 env APP_DIR="$APP3" sh "$ROOT/chat.sh" > "$APP3/out.txt" 2>&1
echo "  exit code: $?"
check "detected it and logged the fallback" "grep -q 'fallback /tmp ok' '$APP3/chat.log'"
check "ran the binary from /tmp"            "grep -q 'runner: /tmp/kindlechat-llama' '$APP3/chat.log'"
check "inference still happened"            "head -1 '$APP3/last.txt' | grep -q 'little robot'"
check "no error screen was shown"           "! grep -q 'E-INK HACK - ERROR' '$APP3/out.txt'"
rm -f /tmp/kindlechat-llama
echo

# --- scenario 4: automatic runner selection ----------------------------------
# fp32 is the default because it measured faster on the KT4 (8.2 vs 5.5 tok/s).

echo "--- scenario 4: with both available, must prefer fp32 ---"
APP4="$WORK/both"
mkdir -p "$APP4/model"
cp "$APP/llama" "$APP4/llama"
cp "$APP/llama" "$APP4/llama-q8"
: > "$APP4/model/stories15M.bin"
: > "$APP4/model/stories15M_q80.bin"
: > "$APP4/model/tokenizer.bin"
cat > "$APP4/chat.conf" <<'CONF'
PROMPT="prefer fp32"
STEPS=3
MAX_WAIT=1
CONF

timeout 15 env APP_DIR="$APP4" sh "$ROOT/chat.sh" > "$APP4/out.txt" 2>&1
echo "  exit code: $?"
check "picked fp32 (faster on the KT4)"  "grep -q 'variant=fp32' '$APP4/chat.log'"
check "picked the llama runner"          "grep -q 'runner: $APP4/llama$' '$APP4/chat.log'"
check "picked the fp32 model"            "grep -q 'model: $APP4/model/stories15M.bin' '$APP4/chat.log'"
check "and inference ran"                "head -1 '$APP4/last.txt' | grep -q 'little robot'"
echo

# --- scenario 4b: with no fp32 pair, falls back to Q8 ------------------------

echo "--- scenario 4b: with the fp32 pair missing, must use Q8 ---"
APP4b="$WORK/q8only"
mkdir -p "$APP4b/model"
cp "$APP/llama" "$APP4b/llama-q8"
: > "$APP4b/model/stories15M_q80.bin"
: > "$APP4b/model/tokenizer.bin"
cat > "$APP4b/chat.conf" <<'CONF'
PROMPT="only q8 installed"
STEPS=3
MAX_WAIT=1
CONF

timeout 15 env APP_DIR="$APP4b" sh "$ROOT/chat.sh" > "$APP4b/out.txt" 2>&1
echo "  exit code: $?"
check "fell back to variant Q8_0"        "grep -q 'variant=Q8_0' '$APP4b/chat.log'"
check "picked llama-q8"                  "grep -q 'runner: $APP4b/llama-q8$' '$APP4b/chat.log'"
check "picked the _q80.bin model"        "grep -q 'model: $APP4b/model/stories15M_q80.bin' '$APP4b/chat.log'"
echo

# --- scenario 5: chat.conf overrides the automatic pick ----------------------

echo "--- scenario 5: chat.conf can force a specific pair ---"
APP5="$WORK/forced"
mkdir -p "$APP5/model"
cp "$APP/llama" "$APP5/llama"
cp "$APP/llama" "$APP5/llama-q8"
: > "$APP5/model/stories15M.bin"
: > "$APP5/model/stories15M_q80.bin"
: > "$APP5/model/tokenizer.bin"
cat > "$APP5/chat.conf" <<'CONF'
PROMPT="forced in the conf"
STEPS=3
MAX_WAIT=1
BIN="$APP_DIR/llama"
MODEL="$APP_DIR/model/stories15M.bin"
CONF

timeout 15 env APP_DIR="$APP5" sh "$ROOT/chat.sh" > "$APP5/out.txt" 2>&1
echo "  exit code: $?"
check "honoured BIN from chat.conf"      "grep -q 'runner: $APP5/llama$' '$APP5/chat.log'"
check "honoured MODEL from chat.conf"    "grep -q 'model: $APP5/model/stories15M.bin' '$APP5/chat.log'"
check "marked it as variant=config"      "grep -q 'variant=config' '$APP5/chat.log'"
echo

# --- scenario 6: what chat.sh asks fbink to draw -----------------------------
# This scenario exists because of two real bugs:
#   1) passing "-r" to fbink thinking it was refresh (it is "--rpadded": pads
#      the line with spaces and makes the whole panel flash)
#   2) a long prompt wrapping and pushing the model output down
# With a fake fbink that only records what it received, both are checkable.

echo "--- scenario 6: fbink calls (no -r, prompt truncated) ---"
APP6="$WORK/fbink"
mkdir -p "$APP6/model"

cat > "$APP6/fbink-stub" <<'STUB'
#!/bin/sh
printf '[fbink] args: %s\n' "$*" >> "$FBINK_LOG"
# record the drawn content (header and stream both arrive on stdin)
while IFS= read -r _l; do
    printf '[fbink] text: %s\n' "$_l" >> "$FBINK_LOG"
done
exit 0
STUB
chmod +x "$APP6/fbink-stub"

cp "$APP/llama" "$APP6/llama"
: > "$APP6/model/stories15M.bin"
: > "$APP6/model/tokenizer.bin"

# deliberately much longer than the screen
LONG_PROMPT="Once upon a time, there was a little robot who lived in a very big house with many friends and lots of toys and he was happy every single day of his life"
cat > "$APP6/chat.conf" <<CONF
PROMPT="$LONG_PROMPT"
STEPS=3
MAX_WAIT=1
CONF

rm -f "$APP6/fbink.log"
# FB_COLS pins the panel width: without it the script reads this PC's real
# framebuffer and the "long" prompt fits, which is not what a KT4 (800 px) does.
timeout 15 env APP_DIR="$APP6" FBINK="$APP6/fbink-stub" FBINK_LOG="$APP6/fbink.log" FB_COLS=60 \
    sh "$ROOT/chat.sh" < /dev/null > "$APP6/out.txt" 2>&1
echo "  exit code: $?"
echo "  --- recorded calls ---"
sed 's/^/      /' "$APP6/fbink.log" 2>/dev/null

check "fbink was called"                 "test -s '$APP6/fbink.log'"
check "NO call uses -r"                  "! grep -q -- ' -r' '$APP6/fbink.log'"
check "the header was drawn"             "grep -q 'text: .*E-INK HACK' '$APP6/fbink.log'"
check "the variant shows in the header"  "grep -q 'text: Model  : .*(fp32)' '$APP6/fbink.log'"
check "the model stream was drawn"       "grep -q 'args: -y $STREAM_LINE' '$APP6/fbink.log'"
check "the long prompt was truncated"    "grep -q 'text: Prompt : .*\.\.\.$' '$APP6/fbink.log'"
check "the prompt tail was NOT drawn"    "! grep -q 'happy every single day' '$APP6/fbink.log'"
check "the model output was not cut"     "grep -q 'little robot' '$APP6/last.txt'"
echo

if [ "$FAIL" = "0" ]; then
    echo "RESULT: all good"
else
    echo "RESULT: something failed"
fi
exit $FAIL
