#!/bin/sh
# Name: E-INK HACK
# Author: Daniel Kumanaya
# Description: Offline chat on the Kindle (llama2.c + TinyStories 15M). Inference MVP.
# Icon: /mnt/us/extensions/kindlechat/icon.png   <- uncomment after adding the PNG
# DontUseFBInk
#
# Install layout:
#   /mnt/us/documents/chat.sh                 <- this file (the scriptlet)
#   /mnt/us/extensions/kindlechat/llama       <- fp32 binary (run.c)
#   /mnt/us/extensions/kindlechat/llama-q8    <- Q8 binary (runq.c), optional
#   /mnt/us/extensions/kindlechat/model/stories15M.bin
#   /mnt/us/extensions/kindlechat/model/stories15M_q80.bin   <- optional (Q8)
#   /mnt/us/extensions/kindlechat/model/tokenizer.bin
#   /mnt/us/extensions/kindlechat/chat.conf

APP_DIR="${APP_DIR:-/mnt/us/extensions/kindlechat}"
OUT="$APP_DIR/last.txt"
LOG="$APP_DIR/chat.log"
CFG="$APP_DIR/chat.conf"
FLAG="$APP_DIR/.tapped"

FBINK="${FBINK:-/mnt/us/libkh/bin/fbink}"
[ -x "$FBINK" ] || FBINK="$(command -v fbink 2>/dev/null)"

PROMPT="Once upon a time, there was a little robot"
STEPS=80
TEMP=0.8
TOPP=0.9
STREAM_LINE=8
STATUS_LINE=28
MAX_WAIT=600

# BIN and MODEL may come from chat.conf; if they do not, they are picked below.
BIN="${BIN:-}"
MODEL="${MODEL:-}"

[ -r "$CFG" ] && . "$CFG"

# Pick the runner+model pair.
#
# fp32 comes first on purpose: measured on the KT4, Q8_0 was SLOWER (5.5 tok/s
# against 8.2). That is a compiler decision, not a format one: LLVM disables the
# "neonfp" feature on the ARMv7 CPUs of this target, so fp32 floating point ends
# up as scalar VFP while the quantized path pays int<->float conversions without
# making it back. Q8 is still useful for size alone (16 MB against 58 MB).
# To force Q8, uncomment BIN/MODEL in chat.conf.
if [ -z "$BIN" ] || [ -z "$MODEL" ]; then
    if [ -e "$APP_DIR/llama" ] && [ -e "$APP_DIR/model/stories15M.bin" ]; then
        BIN="${BIN:-$APP_DIR/llama}"
        MODEL="${MODEL:-$APP_DIR/model/stories15M.bin}"
        VARIANT="fp32"
    else
        BIN="${BIN:-$APP_DIR/llama-q8}"
        MODEL="${MODEL:-$APP_DIR/model/stories15M_q80.bin}"
        VARIANT="Q8_0"
    fi
else
    VARIANT="config"
fi
TOKENIZER="${TOKENIZER:-$APP_DIR/model/tokenizer.bin}"

log() {
    mkdir -p "$APP_DIR" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

say() {
    # No -r here: fbink's "-r" is "--rpadded" (pads the line with spaces up to
    # the edge), NOT refresh. It only widens the redrawn area and makes the
    # panel flash more. Refresh is already fbink's default behaviour.
    if [ -n "$FBINK" ]; then
        "$FBINK" -y "$1" "$2" >/dev/null 2>&1
    else
        echo "$2"
    fi
}

# Available columns, so nothing in the header wraps and pushes the model output
# down. fbink uses a fixed 8 px wide font.
#
# FB_COLS overrides the panel size, for tests (and for the rare device whose
# framebuffer reports something odd).
fb_cols() {
    case "${FB_COLS:-}" in
        ''|*[!0-9]*) ;;
        *) echo "$FB_COLS"; return ;;
    esac
    W=""
    if [ -r /sys/class/graphics/fb0/virtual_size ]; then
        W="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
        W="${W%%,*}"
    fi
    case "$W" in
        ''|*[!0-9]*) echo 60 ;;
        *) echo $((W / 8)) ;;
    esac
}

# Cut the text to N columns, with an ellipsis if it was cut.
truncate() {
    LIM="$2"
    if [ "${#1}" -le "$LIM" ]; then
        printf '%s' "$1"
    else
        printf '%s...' "$(printf '%s' "$1" | cut -c1-$((LIM - 3)))"
    fi
}

header() {
    if [ -n "$FBINK" ]; then
        COLS="$(fb_cols)"
        {
            echo "=========================================="
            echo "               E-INK HACK"
            echo "=========================================="
            echo "Model  : TinyStories 15M  ($VARIANT)"
            echo "Prompt : $(truncate "$PROMPT" $((COLS - 9)))"
            echo "Tokens : $STEPS    temp=$TEMP  top-p=$TOPP"
            echo "------------------------------------------"
        } | "$FBINK" -y 0 >/dev/null 2>&1
    fi
}

check_env() {
    # /mnt/us is sometimes mounted without the execute bit. If the binary exists
    # but is not executable, copy it to /tmp (tmpfs, always exec) and run there.
    RUN=""
    if [ -x "$BIN" ]; then
        RUN="$BIN"
    elif [ -e "$BIN" ]; then
        log "binary has no execute bit; trying a copy in /tmp"
        if cp "$BIN" /tmp/kindlechat-llama 2>/dev/null && chmod +x /tmp/kindlechat-llama 2>/dev/null; then
            RUN=/tmp/kindlechat-llama
            log "fallback /tmp ok"
        fi
    fi

    [ -n "$RUN" ] || log "ERROR: binary missing or not executable: $BIN"
    [ -r "$MODEL" ] || log "ERROR: model missing: $MODEL"
    [ -r "$TOKENIZER" ] || log "ERROR: tokenizer missing: $TOKENIZER"
}

show_error() {
    if [ ! -e "$BIN" ]; then
        REASON="Cannot find: $BIN"
    elif [ -z "$RUN" ]; then
        REASON="The binary exists but will not run
(no execute bit on /mnt/us)."
    elif [ ! -r "$MODEL" ]; then
        REASON="Cannot find: $MODEL"
    elif [ ! -r "$TOKENIZER" ]; then
        REASON="Cannot find: $TOKENIZER"
    else
        REASON="Environment error."
    fi

    ERROR_TEXT="E-INK HACK - ERROR
==========================================

$REASON

Expected under $APP_DIR:
  llama      or  llama-q8
  model/stories15M.bin   (or stories15M_q80.bin)
  model/tokenizer.bin
  chat.conf

Tap to go back."

    if [ -n "$FBINK" ]; then
        printf '%s\n' "$ERROR_TEXT" | "$FBINK" -y 0 >/dev/null 2>&1
    else
        printf '%s\n' "$ERROR_TEXT"
    fi
    log "error screen shown to the user"
}

run_inference() {
    log "inference: steps=$STEPS t=$TEMP p=$TOPP variant=$VARIANT"
    log "prompt: $PROMPT"
    log "runner: $RUN"
    log "model: $MODEL"

    if [ -n "$FBINK" ]; then
        "$RUN" "$MODEL" -z "$TOKENIZER" -t "$TEMP" -p "$TOPP" -n "$STEPS" -i "$PROMPT" \
            2>>"$LOG" | tee "$OUT" 2>/dev/null | "$FBINK" -y "$STREAM_LINE" >/dev/null 2>&1
    else
        "$RUN" "$MODEL" -z "$TOKENIZER" -t "$TEMP" -p "$TOPP" -n "$STEPS" -i "$PROMPT" \
            2>>"$LOG" | tee "$OUT"
    fi

    TOKS_PER_S="$(grep -o 'achieved tok/s: [0-9.]*' "$LOG" 2>/dev/null | tail -1 | sed 's/.*: //')"
    [ -z "$TOKS_PER_S" ] && TOKS_PER_S="?"
    log "tok/s: $TOKS_PER_S"
    say "$STATUS_LINE" "tok/s: $TOKS_PER_S   (tap to exit)"
}

find_touch_device() {
    D=$(awk '
        $1 == "Section" && $2 == "\"InputDevice\"" { inSec = 1; dev = ""; found = 0 }
        inSec && $2 == "\"Device\"" { dev = $3 }
        inSec && $2 == "\"CorePointer\"" && dev != "" { found = 1 }
        inSec && $1 == "EndSection" {
            if (found && dev != "") { gsub(/"/, "", dev); print dev; exit }
            inSec = 0; dev = ""; found = 0
        }
    ' /etc/xorg.conf 2>/dev/null)
    [ -n "$D" ] && [ -e "$D" ] && { echo "$D"; return; }

    D=$(awk '
        /^N: Name=/ {
            name = $0
            sub(/^N: Name="/, "", name)
            sub(/"$/, "", name)
            ev = ""
        }
        /^H: Handlers=/ {
            for (i = 1; i <= NF; i++) {
                t = $i
                sub(/^Handlers=/, "", t)
                if (t ~ /^event[0-9]+$/) ev = t
            }
        }
        /^B: ABS=/ {
            if (ev != "") {
                if (tolower(name) ~ /(touch|zforce|cyttsp|elan|goodix|ft5|atmel|synaptics|eink|st1232)/) {
                    if (best == "") best = ev
                }
                if (fallback == "") fallback = ev
            }
        }
        END {
            if (best != "") print "/dev/input/" best
            else if (fallback != "") print "/dev/input/" fallback
        }
    ' /proc/bus/input/devices 2>/dev/null)
    [ -n "$D" ] && [ -e "$D" ] && { echo "$D"; return; }

    for D in /dev/input/event1 /dev/input/event0 /dev/input/event2; do
        [ -e "$D" ] && { echo "$D"; return; }
    done
}

wait_for_tap() {
    DEV=$(find_touch_device)
    if [ -z "$DEV" ]; then
        log "no touch device found; holding for 120s"
        sleep 120
        return
    fi
    log "waiting for a tap on $DEV"

    rm -f "$FLAG"
    dd if="$DEV" bs=16 count=1 >/dev/null 2>&1 && touch "$FLAG" &
    JOB=$!

    N=0
    while [ ! -f "$FLAG" ]; do
        sleep 1
        N=$((N + 1))
        if [ "$N" -ge "$MAX_WAIT" ]; then
            log "timeout after ${MAX_WAIT}s"
            kill "$JOB" 2>/dev/null
            for P in $(pidof dd 2>/dev/null); do kill "$P" 2>/dev/null; done
            break
        fi
    done

    wait "$JOB" 2>/dev/null
    rm -f "$FLAG"
}

leave() {
    [ -n "$FBINK" ] && "$FBINK" -c >/dev/null 2>&1
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home >/dev/null 2>&1
}

log "=== start (steps=$STEPS) ==="
check_env

if [ -z "$RUN" ] || [ ! -r "$MODEL" ] || [ ! -r "$TOKENIZER" ]; then
    show_error
    log "aborting: incomplete environment"
    wait_for_tap
    leave
    exit 1
fi

header
run_inference
wait_for_tap
leave
