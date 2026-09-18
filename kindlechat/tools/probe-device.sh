#!/bin/sh
# Collects Kindle information, to calibrate the build and the UI.
#
# Run ON THE KINDLE (KTerm or SSH):
#     sh /mnt/us/kindlechat-probe.sh
#
# Writes the report to the screen and also to /mnt/us/kindlechat-probe.txt
# (copy that file over USB).
#
# Optional (the keyboard appears on screen):
#     sh /mnt/us/kindlechat-probe.sh --kbd-test

OUT="/mnt/us/kindlechat-probe.txt"
KBD_TEST=0
[ "$1" = "--kbd-test" ] && KBD_TEST=1

mkdir -p /mnt/us 2>/dev/null

{
    echo "===== E-INK HACK PROBE ====="
    echo "date: $(date)"
    echo

    echo "--- firmware / kernel / cpu ---"
    echo "version   : $(cat /etc/version 2>/dev/null)"
    echo "uname     : $(uname -a 2>/dev/null)"
    echo "arch      : $(uname -m 2>/dev/null)"
    echo "model     : $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
    grep -m1 -i 'model name\|Processor\|Hardware' /proc/cpuinfo 2>/dev/null
    grep -m1 -i '^Features' /proc/cpuinfo 2>/dev/null
    echo "neon      : $(grep -qi neon /proc/cpuinfo && echo YES || echo no)"
    echo

    echo "--- userspace ABI (decides kindlehf vs kindlepw2) ---"
    echo "ldd       : $(command -v ldd 2>/dev/null || echo missing)"
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig -p 2>/dev/null | grep -m2 'libc\.so' || true
    fi
    ls -l /lib/ld-*.so* /lib/ld-linux*.so* 2>/dev/null
    echo

    echo "--- memory ---"
    grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal' /proc/meminfo 2>/dev/null
    echo

    echo "--- disk ---"
    df -h /mnt/us 2>/dev/null
    df -h / 2>/dev/null
    echo

    echo "--- screen ---"
    echo "virtual_size    : $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
    echo "bits_per_pixel  : $(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)"
    echo "stride          : $(cat /sys/class/graphics/fb0/stride 2>/dev/null)"
    echo

    echo "--- fbink ---"
    if [ -x /mnt/us/libkh/bin/fbink ]; then
        echo "path   : /mnt/us/libkh/bin/fbink"
        echo "size   : $(wc -c < /mnt/us/libkh/bin/fbink 2>/dev/null) bytes"
    else
        echo "path   : MISSING at /mnt/us/libkh/bin/fbink"
        echo "other  : $(command -v fbink 2>/dev/null || echo none)"
    fi
    ls -l /mnt/us/libkh 2>/dev/null
    echo

    echo "--- input devices ---"
    ls -l /dev/input 2>/dev/null
    echo
    echo "(/proc/bus/input/devices)"
    cat /proc/bus/input/devices 2>/dev/null
    echo

    echo "--- xorg.conf (CorePointer) ---"
    if [ -r /etc/xorg.conf ]; then
        grep -n -A2 -B2 'CorePointer\|InputDevice' /etc/xorg.conf 2>/dev/null | head -40
    else
        echo "missing"
    fi
    echo

    echo "--- boot / framework ---"
    echo "upstart framework: $(ls /etc/upstart/framework.conf 2>/dev/null || echo missing)"
    echo "appmgrd          : $(pgrep -f appmgrd 2>/dev/null | head -3 | tr '\n' ' ')"
    echo

    echo "--- available tools ---"
    for t in awk sed grep dd pidof timeout lipc-get-prop lipc-wait-event eips lipc-set-prop tee fbink; do
        p=$(command -v "$t" 2>/dev/null)
        if [ -n "$p" ]; then printf '%-16s %s\n' "$t" "$p"; else printf '%-16s MISSING\n' "$t"; fi
    done
    echo

    echo "--- native keyboard (LIPC) ---"
    if command -v lipc-get-prop >/dev/null 2>&1; then
        for p in bounds height show appID language preedit; do
            printf '%-10s = %s\n' "$p" "$(lipc-get-prop com.lab126.keyboard $p 2>/dev/null)"
        done
    else
        echo "lipc-get-prop missing"
    fi

    if [ "$KBD_TEST" = "1" ]; then
        echo
        echo "--- test: opening the native keyboard ---"
        lipc-set-prop com.lab126.keyboard open 1 2>&1 && echo "open  -> ok" || echo "open  -> failed"
        sleep 5
        lipc-set-prop com.lab126.keyboard close 1 2>&1 && echo "close -> ok" || echo "close -> failed"
    fi

    echo
    echo "===== END ====="
} 2>&1 | tee "$OUT"

echo
echo "report saved to $OUT"
echo "copy that file over USB."
