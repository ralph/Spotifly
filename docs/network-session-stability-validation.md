# Network + Session Stability Validation

Date: 2026-02-21  
Step: `#7 Validation and regression matrix`

## What Was Validated Here

- Reconnect metric extraction tooling was added:
  - `/Users/ralph/code/spotifly/repos/rust/scripts/reconnect_metrics.sh`
- Existing local log files were analyzed:
  - `/Users/ralph/code/spotifly/repos/foo.log`
  - `/Users/ralph/code/spotifly/repos/recently-played.log`

Command run:

```bash
/Users/ralph/code/spotifly/repos/rust/scripts/reconnect_metrics.sh \
  /Users/ralph/code/spotifly/repos/foo.log \
  /Users/ralph/code/spotifly/repos/recently-played.log
```

Observed result:

- `No [RECONNECT_TRACE] events found in the provided logs.`

## Baseline Metric Comparison

Baseline metrics defined in plan:

- `time_to_ready_ms`
- `time_to_first_playing_ms`
- `token_latency_ms`
- `reconnect_success_rate`

Current result in this environment:

- `n=0` reconnect traces in available logs, so no numeric comparison is possible here yet.

## Scenario Matrix

| Scenario | Status | Notes |
|---|---|---|
| Local playback (AP drop + auto-reconnect) | Not run in sandbox | Requires live Spotify session and controlled network interruption. |
| Remote-controlled playback during reconnect | Not run in sandbox | Requires second Spotify client/device and live Connect state. |
| Sleep/wake reconnect | Not run in sandbox | Requires macOS sleep/wake cycle with running app session. |
| Forced network drop | Not run in sandbox | Requires local firewall/network toggling against Spotify AP/dealer endpoints. |

## Residual Risks

1. Deferred local transport replay keeps only the latest deferred command; rapid multi-command bursts during reconnect may collapse to the last intent.
2. `sessionDisconnected` Swift callback represents reconnect exhaustion, not each transient disconnect, so UI-level failure messaging is delayed by retry policy.
3. Audio continuity outcomes (audible gap/jolt duration) are still unquantified until fresh `RECONNECT_TRACE` logs are collected from a live run.

## Follow-up Runbook (on your machine)

1. Run Spotifly with reconnect tracing enabled and reproduce each matrix scenario.
2. Save logs that include `[RECONNECT_TRACE]` events.
3. Run:
   ```bash
   /Users/ralph/code/spotifly/repos/rust/scripts/reconnect_metrics.sh /path/to/spotifly.log
   ```
4. Compare reported metrics against your pre-change baseline and append the numbers to this document.
