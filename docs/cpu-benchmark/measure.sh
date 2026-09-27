#!/bin/bash
# Steady-state cost of a running Spotifly, written to <label>/ next to this script.
#
#   docs/cpu-benchmark/measure.sh <label>
#
# 60 s of CPU time for the app and for coreaudiod, then 30 s of idle wakeups and
# energy impact from top, then a 30 s Time Profiler trace attached with xctrace
# and exported as XML for aggregate.py. Start it once playback (or the pause) has
# settled; nothing else heavy should run meanwhile.
set -euo pipefail

LABEL=$1
PID=$(pgrep -x Spotifly)
[ "$(echo "$PID" | wc -l)" -eq 1 ] || { echo "expected exactly one Spotifly process" >&2; exit 1; }
OUT="$(cd "$(dirname "$0")" && pwd)/results/$LABEL"
mkdir -p "$OUT"

# ps prints cputime as [hh:]mm:ss.cc.
secs() { ps -o cputime= -p "$1" | awk -F'[:.]' '{ if (NF == 4) print $1*3600 + $2*60 + $3 + $4/100; else print $1*60 + $2 + $3/100 }'; }
AUDIO=$(pgrep -x coreaudiod)

a=$(secs "$PID"); c=$(secs "$AUDIO"); sleep 60; b=$(secs "$PID"); d=$(secs "$AUDIO")
{
    awk -v a="$a" -v b="$b" -v c="$c" -v d="$d" 'BEGIN { printf "cpu_app_pct=%.2f\ncpu_coreaudiod_pct=%.2f\n", (b - a) * 100 / 60, (d - c) * 100 / 60 }'
    echo "rss_mb=$(( $(ps -o rss= -p "$PID" | tr -d ' ') / 1024 ))"
    echo "threads=$(( $(ps -M -p "$PID" | wc -l) - 1 ))"
    # top's IDLEW counts since launch, so the rate is the difference of two samples.
    top -l 2 -s 30 -pid "$PID" -stats pid,idlew,power 2>/dev/null | awk -v pid="$PID" '
        $1 == pid { gsub(/[+-]/, "", $2); w[n++] = $2; p = $3 }
        END { printf "idle_wakeups_per_s=%.1f\nenergy_impact=%s\n", (w[1] - w[0]) / 30, p }'
} | tee "$OUT/summary.txt"

xcrun xctrace record --template 'Time Profiler' --attach "$PID" --time-limit 30s --output "$OUT/profile.trace" > /dev/null
xcrun xctrace export --input "$OUT/profile.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$OUT/profile.xml"
python3 "$(dirname "$0")/aggregate.py" "$OUT/profile.xml" 30 > "$OUT/profile.txt"
head -12 "$OUT/profile.txt"
