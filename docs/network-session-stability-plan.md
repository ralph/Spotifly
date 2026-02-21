# Network + Session Stability Plan

Status: Active  
Review mode: Step-by-step (one numbered item at a time, user review before commit)

## Checklist

- [x] #1 Baseline instrumentation
  - Add reconnect lifecycle timing logs (disconnect detected, token requested/received, reconnect start, reconnect ready, first playable event).
  - Emit one structured reconnect trace ID per reconnect attempt for correlation across Swift + Rust logs.
  - Define baseline metrics we will compare after each change (time-to-ready, time-to-first-audio, reconnect success rate).

- [x] #2 Implement soft reconnect in Rust FFI
  - Keep existing `Player`, `Mixer`, and `ProxySink` alive across AP disconnects.
  - Recreate only `Session` + `Spirc`, then rebind `Player` via `player.set_session(new_session)`.
  - Recreate dealer/cluster listeners for the new session generation.

- [x] #3 Keep hard reconnect as fallback
  - Preserve current full cleanup path as fallback when soft reconnect fails.
  - Add bounded retry/timeout policy for soft reconnect before fallback is triggered.
  - Ensure fallback path remains deterministic and observable in logs.

- [x] #4 Improve short-outage tolerance
  - Tune buffering/read-ahead behavior to better survive brief AP disruptions.
  - Validate that tuning does not regress startup latency or seek responsiveness.
  - Log effective buffering parameters at init for reproducibility.

- [x] #5 Reduce reconnect-induced playback jolts
  - Make post-reconnect activation/transfer behavior conditional.
  - Avoid unnecessary `transfer(None)` calls that can disturb active playback state.
  - Keep device activation semantics correct for fresh start vs reconnect.

- [x] #6 Swift-side recovery hardening
  - Subscribe to and handle session-disconnected failure signals in Swift.
  - Handle actionable FFI return codes in transport controls with reconnect-aware retry/defer behavior.
  - Keep UI/store connection state coherent during reconnect transitions.

- [ ] #7 Validation and regression matrix
  - Run repeatable scenarios: local playback, remote-controlled playback, sleep/wake, forced network drop.
  - Compare against baseline metrics and document results.
  - Record residual risks and follow-up items.

## Execution Rules

1. Work only one numbered step at a time (`#1`, then `#2`, ...).
2. After each step, stop for user inspection before commit.
3. Keep this file current by checking off completed steps.
4. If scope changes, update this plan first, then implement.

## Baseline Metrics

- `time_to_ready_ms`
  - Definition: elapsed time from `trace_started` to `session_connected_event`.
  - Source: Rust reconnect trace log (`[RECONNECT_TRACE]`).

- `time_to_first_playing_ms`
  - Definition: elapsed time from `trace_started` to first local `PlayerEvent::Playing` after reconnect.
  - Source: Rust reconnect trace log (`[RECONNECT_TRACE]`).
  - Note: present only when reconnect is expected to resume active playback.

- `token_latency_ms`
  - Definition: elapsed time from token request to token receipt (`token_requested` → `token_received`).
  - Source: Rust reconnect trace log + Swift token callback logs.

- `reconnect_success_rate`
  - Definition: successful reconnect traces / started reconnect traces.
  - Source: count of `trace_started` vs `session_connected_event`/`reconnect_exhausted` phases.
