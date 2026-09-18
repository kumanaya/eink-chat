#!/bin/sh
# Headless checks for chat-ui: host build, parsing self-test, and a short run
# under broadwayd (GTK's headless display) when it is installed.
#
#   sh tests/chatui-smoke.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/out/chat-ui"

echo "--- build (host) ---"
sh "$ROOT/tools/build-chatui.sh"

echo "--- self-test ---"
"$BIN" --self-test

echo "--- version ---"
"$BIN" --version

if command -v broadwayd >/dev/null 2>&1; then
    echo "--- broadwayd window smoke run ---"
    PORT=8093
    DISP=:7
    broadwayd --port "$PORT" "$DISP" >/dev/null 2>&1 &
    BPID=$!
    trap 'kill "$BPID" 2>/dev/null || true' EXIT INT TERM
    sleep 1
    set +e
    GDK_BACKEND=broadway BROADWAY_DISPLAY="$DISP" timeout 3 "$BIN" --no-spawn --port 8099 >/dev/null 2>&1
    RC=$?
    set -e
    if [ "$RC" != "124" ]; then
        echo "  FAILED: chat-ui exited with $RC (expected to be killed by timeout)" >&2
        exit 1
    fi
    echo "  ok: the window stayed up"
else
    echo "--- broadwayd not found: skipping the window smoke run ---"
fi

echo
echo "RESULT: all good"
