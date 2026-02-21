#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <log-file> [log-file ...]"
  echo "Parses [RECONNECT_TRACE] JSON log events and prints reconnect metrics."
  exit 1
fi

for file in "$@"; do
  if [ ! -f "$file" ]; then
    echo "File not found: $file" >&2
    exit 1
  fi
done

tmp_raw="$(mktemp)"
tmp_json="$(mktemp)"
tmp_valid="$(mktemp)"
trap 'rm -f "$tmp_raw" "$tmp_json" "$tmp_valid"' EXIT

if ! rg --no-heading '\[RECONNECT_TRACE\]' "$@" > "$tmp_raw"; then
  echo "No [RECONNECT_TRACE] events found in the provided logs."
  exit 0
fi

sed -E 's/^.*\[RECONNECT_TRACE\] //' "$tmp_raw" > "$tmp_json"

while IFS= read -r line; do
  if printf '%s\n' "$line" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$line" >> "$tmp_valid"
  fi
done < "$tmp_json"

if [ ! -s "$tmp_valid" ]; then
  echo "Found [RECONNECT_TRACE] lines, but none contained valid JSON payloads."
  exit 1
fi

unique_count_for_phase() {
  local phase="$1"
  jq -r "select(.phase==\"${phase}\") | .trace_id" "$tmp_valid" | sort -u | wc -l | tr -d ' '
}

summarize_metric() {
  local label="$1"
  local filter="$2"
  local sorted_values
  sorted_values="$(jq -r "$filter" "$tmp_valid" | sort -n)"

  if [ -z "$sorted_values" ]; then
    printf "%-26s %5s %8s %8s %8s %8s\n" "$label" "0" "-" "-" "-" "-"
    return
  fi

  local stats
  stats="$(printf '%s\n' "$sorted_values" | awk '
    NF {
      values[++n] = $1
      sum += $1
    }
    END {
      p50_idx = int((n + 1) / 2)
      p95_idx = int((n * 95 + 99) / 100)
      if (p95_idx < 1) p95_idx = 1
      if (p95_idx > n) p95_idx = n
      avg = sum / n
      printf "%d %.0f %.0f %.0f %.0f\n", n, avg, values[p50_idx], values[p95_idx], values[n]
    }')"

  local count avg p50 p95 max
  read -r count avg p50 p95 max <<< "$stats"
  printf "%-26s %5s %8s %8s %8s %8s\n" "$label" "$count" "$avg" "$p50" "$p95" "$max"
}

event_count="$(wc -l < "$tmp_valid" | tr -d ' ')"
trace_count="$(jq -r '.trace_id' "$tmp_valid" | sort -u | wc -l | tr -d ' ')"
started_count="$(unique_count_for_phase "trace_started")"
connected_count="$(unique_count_for_phase "session_connected_event")"
exhausted_count="$(unique_count_for_phase "reconnect_exhausted")"
fallback_count="$(unique_count_for_phase "fallback_to_hard")"

if [ "$started_count" -gt 0 ]; then
  success_rate="$(awk -v success="$connected_count" -v started="$started_count" 'BEGIN { printf "%.1f%%", (success / started) * 100 }')"
else
  success_rate="n/a"
fi

echo "Reconnect Trace Metrics"
echo "======================="
echo "Files analyzed: $*"
echo "Valid reconnect events: $event_count"
echo "Unique traces: $trace_count"
echo
echo "Trace outcomes"
echo "--------------"
echo "Started traces:        $started_count"
echo "Connected traces:      $connected_count"
echo "Exhausted traces:      $exhausted_count"
echo "Hard fallback traces:  $fallback_count"
echo "Reconnect success rate: $success_rate"
echo
echo "Latency metrics (ms)"
echo "--------------------"
printf "%-26s %5s %8s %8s %8s %8s\n" "metric" "count" "avg" "p50" "p95" "max"
summarize_metric "time_to_ready_ms" 'select(.phase=="session_connected_event" and .time_to_ready_ms != null) | .time_to_ready_ms'
summarize_metric "time_to_first_playing_ms" 'select(.phase=="first_playing" and .time_to_first_playing_ms != null) | .time_to_first_playing_ms'
summarize_metric "token_latency_ms" 'select(.phase=="token_received" and .token_latency_ms != null) | .token_latency_ms'
