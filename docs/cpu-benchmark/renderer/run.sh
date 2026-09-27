#!/bin/bash
# Cost of the app's AudioRenderer on its own, fed like the pipeline feeds it,
# with no Spotify, UI or login involved. Prints the CPU and idle wakeups of the
# 60 s after a 10 s settle.
#
#   docs/cpu-benchmark/renderer/run.sh [<git revision>] [pause]
#
# Builds AudioRenderer.swift from the working tree, or from <git revision> to
# compare. `pause` pauses for 4 s after 3 s, before the measured window. The
# signal is -120 dB noise: inaudible, but not silence the output could skip.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REV=""
MODE=""
for arg in "$@"; do
    if [ "$arg" = pause ]; then MODE=pause; else REV=$arg; fi
done
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The renderer took `enqueue` with macOS 27; before that it was written to
# through the AudioSink protocol, and legacy.swift drives it that way.
DRIVER="$HERE/main.swift"
for file in Spotifly/AudioRenderer.swift Spotifly/SwiftLibrespot/Audio/AudioSink.swift; do
    if [ -n "$REV" ]; then
        git -C "$ROOT" show "$REV:$file" > "$WORK/$(basename "$file")" 2> /dev/null || rm "$WORK/$(basename "$file")"
    elif [ -f "$ROOT/$file" ]; then
        cp "$ROOT/$file" "$WORK/"
    fi
done
[ -f "$WORK/AudioSink.swift" ] && DRIVER="$HERE/legacy.swift"
# Top-level code has to be in main.swift.
cp "$DRIVER" "$WORK/main.swift"
swiftc -O -swift-version 6 "$HERE/shim.swift" "$WORK"/*.swift \
    -o "$WORK/renderer" 2> "$WORK/build.log" || { cat "$WORK/build.log" >&2; exit 1; }

"$WORK/renderer" 75 $MODE > "$WORK/out.txt" &
PID=$!
sleep 10
secs() { ps -o cputime= -p "$1" | awk -F'[:.]' '{ if (NF == 4) print $1*3600 + $2*60 + $3 + $4/100; else print $1*60 + $2 + $3/100 }'; }
a=$(secs $PID)
# IDLEW counts since launch, so the rate is the difference of two samples.
wakeups=$(top -l 2 -s 60 -pid $PID -stats pid,idlew,power 2>/dev/null | awk -v pid=$PID '
    $1 == pid { gsub(/[+-]/, "", $2); w[n++] = $2; p = $3 }
    END { printf "idle_wakeups_per_s=%.1f energy_impact=%s", (w[1] - w[0]) / 60, p }')
b=$(secs $PID)
wait $PID
echo "${REV:-working tree}${MODE:+ ($MODE)}: $wakeups cpu_pct=$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.2f", (b - a) * 100 / 60 }'); $(cat "$WORK/out.txt")"
