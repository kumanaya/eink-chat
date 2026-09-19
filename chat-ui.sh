#!/bin/sh
# Name: E-INK HACK CHAT
# Author: Daniel Kumanaya
# Description: Native GTK chat window over llama-server. No KOReader needed.
# DontUseFBInk
#
# Install: copy this file to /mnt/us/documents/ and the binary to
# /mnt/us/extensions/kindlechat/chat-ui (see the README; tools/deploy.ps1 does
# not copy this pair yet).
#
# The window is GTK over the X server the framework already runs, so the
# keyboard, the scrolling and the e-ink repaint are ordinary GTK widgets.
# chat-ui starts and stops llama-server itself when nothing is listening on
# 127.0.0.1:8080 already.
#
# The process stays alive on purpose: sh_integration returns the screen to the
# library when the script exits, and the GTK window lives exactly as long as
# this script. Tapping the window's close button (or leaving it) ends both.

APP_DIR="${APP_DIR:-/mnt/us/extensions/kindlechat}"
BIN="${CHATUI_BIN:-$APP_DIR/chat-ui}"
LOG="$APP_DIR/chat-ui.log"

# The window is an X client; the framework runs Xorg on :0.
export DISPLAY="${DISPLAY:-:0}"

FBINK="${FBINK:-/mnt/us/libkh/bin/fbink}"
[ -x "$FBINK" ] || FBINK="$(command -v fbink 2>/dev/null)"

say() {
    if [ -z "$FBINK" ]; then
        printf '%s\n' "$1"
        return
    fi
    "$FBINK" -c >/dev/null 2>&1
    printf '%s\n' "$1" | "$FBINK" -y 8 >/dev/null 2>&1
}

mkdir -p "$APP_DIR" 2>/dev/null

if [ ! -x "$BIN" ]; then
    say "E-INK CHAT: the chat-ui binary is not installed.

$BIN

Build it with tools/build-chatui.sh --kindle
and copy it to that path."
    sleep 20
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] start $BIN" >> "$LOG" 2>&1

# Ghosting: streamed text leaves residue, so a full panel refresh runs after
# each answer. Set REFRESH_CMD to override it, or to "" to turn it off.
if [ -z "${REFRESH_CMD+x}" ] && [ -n "$FBINK" ]; then
    REFRESH_CMD="$FBINK -q -s"
fi

if [ -n "${REFRESH_CMD:-}" ]; then
    set -- --refresh-cmd "$REFRESH_CMD" "$@"
fi

exec "$BIN" --app-dir "$APP_DIR" --fullscreen --keyboard on "$@" >> "$LOG" 2>&1
