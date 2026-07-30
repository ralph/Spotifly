# Position keeps interpolating during an outage, so it snaps backwards on resume

Status: open, low priority
Component: `Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-07-30, in the run that confirmed the readiness-ordering fix (`b34889c`)

## Symptom

After recovering from a network outage, the displayed position jumps **backwards** by a
few seconds as playback resumes:

```text
19:23:57.102  Resume fallback: loading context … at 99403ms   # Rust's real position
19:23:57.366  Position anchor: 104403 -> 99403                # UI corrects back 5s
```

The correction is the UI catching up to reality, not adopting a wrong value: 99403 ms is
where playback actually stopped. The UI had simply run on past it.

This is **not** the same defect as the one fixed in `b34889c`. That one applied a stale
*server* snapshot (145010 ms, timestamp 144 s old) and jumped back 46 seconds. This is the
residue left after that fix: smaller, locally caused, and visible only briefly.

## Mechanism

Playback position in the UI is interpolated from an anchor plus elapsed wall time, with a
once-a-second drift check against Rust in `checkDriftAndSync()`
(`PlaybackViewModel.swift:943`). The correction is gated twice:

```swift
guard isPlaying else { return }                     // line 964
…
let rustPosition = SpotifyPlayer.positionMs
if rustPosition != lastRustPosition {               // line 970
    let drift = abs(Int32(rustPosition) - Int32(interpolatedPositionMs))
    if drift > 500 { /* re-anchor */ }
}
```

Both gates fail in exactly the situation that needs them:

- When the Player is torn down during a reconnect, Rust's `POSITION_MS` **freezes**. So
  `rustPosition == lastRustPosition` on every tick, and the drift branch is never entered —
  the check is disabled precisely when the UI has drifted furthest.
- `IS_PLAYING` survives the rebuild, so `isPlaying` stays true and the first guard passes.
  The UI therefore keeps interpolating forward while no audio is playing at all.

Observed drift in this run was ~5 s. It is bounded by how long the UI keeps interpolating
past the real stop, not by the length of the outage (which was 71 s here) — during the
first part of the outage the Player was still draining its buffer and `POSITION_MS` was
still moving, so corrections were still happening.

**Not established from the log:** the exact provenance of the 104403 ms anchor. It is
5000 ms ahead of Rust's frozen 99403 ms, suspiciously round, and none of the anchor writers
in `PlaybackViewModel` obviously produces it. Worth pinning down before fixing, in case the
drift is a symptom of something more specific than "interpolation ran on".

## Suggested fix

Stop interpolating when the connection is not ready, rather than relying on a drift check
that the freeze disables. The connection snapshot already carries what is needed
(`sessionConnected`, `spircReady`), and `ConnectionService` already publishes it into
`AppStore`.

Sketch: gate the interpolation (and `checkDriftAndSync`'s position branch) on readiness, so
the position holds still while the session is down and re-anchors on the first real update
after recovery. A held position is honest — playback genuinely is not progressing.

Alternatively, or in addition: drop the `rustPosition != lastRustPosition` condition and
compare against the drift threshold alone. That makes the check do its job when the value
is frozen, at the cost of running the comparison every tick.

## Why this is low priority

- Cosmetic. The audio is correct throughout; only the progress bar is briefly wrong.
- Self-correcting within one update after recovery.
- ~5 s, down from the 46 s that `b34889c` removed.

## Verification

Reproduce: play locally, sever the network long enough for `Connection to server closed`
(≈90 s), restore, and watch the log at the moment of resume. Before a fix there is a
`Position anchor: <larger> -> <smaller>` line. After it, the anchor should already be at or
near Rust's position, with no backwards step.

## Related

- `b34889c` — readiness published only once the session is settled, which removed the much
  larger stale-server jump this residue was hiding behind.
- `1562456` — the rehydrating load that produces the authoritative position on resume.
