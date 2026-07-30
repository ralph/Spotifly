# Position keeps interpolating during an outage, so it snaps backwards on resume

Status: implemented, runtime verification pending
Components: `rust/src/lib.rs`, `Spotifly/ViewModels/PlaybackViewModel.swift`,
`Spotifly/AudioRenderer.swift`
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

The exact 5000 ms provenance is now established. `spotifly_get_position_ms()` was not
returning `POSITION_MS` directly. While `IS_PLAYING` remained true, Rust added the wall
time since the last Player event, capped by this literal:

```rust
let capped_elapsed = elapsed_since_update.min(5000) as u32;
stored_position.saturating_add(capped_elapsed)
```

That turns the last real `99403` ms event into exactly `104403` ms after five seconds.
Swift can adopt that extrapolated value as an anchor. Rehydration correctly uses the raw
`POSITION_MS` value, so it loads at `99403` ms and exposes the artificial five seconds as
a backwards correction.

This is not the audio-buffer size:

- `ProxySink` has no buffer; `Sink::write` forwards PCM directly to Swift.
- `AudioRenderer`'s ring buffer contains 176,400 interleaved `f32` samples, exactly two
  seconds at 44.1 kHz stereo.
- Its real-time throttle likewise allows the decoder at most two seconds of lead.
- `AVSampleBufferAudioRenderer` and AirPlay may add output latency, but no buffer occupancy
  feeds back into `POSITION_MS`, so they cannot produce the exact 5000 ms value.

## Implemented fix

There is now one display clock instead of two:

- Rust returns only the last position reported by the Player. The Player already emits
  position updates every 200 ms, so the removed Rust interpolation added no useful UI
  smoothness.
- Swift remains the sole display interpolator and only advances while the connection is
  ready (`sessionConnected && spircReady`).
- On a ready-to-not-ready transition Swift freezes at Rust's last real position for local
  playback, or at the current displayed position when monitoring a remote device.
- The once-per-second drift check now compares against Rust even when the raw value did not
  change. A frozen Player value is precisely when the old `rustPosition !=
  lastRustPosition` guard suppressed the correction that was needed.
- Readiness transitions run through one `syncConnectionReadiness()`, called both from the
  connection-state callback and from that same once-a-second check. Interpolation now
  depends on the flag, so a single missed callback would stop the progress bar during
  healthy playback — a more visible failure than the drift being prevented. Re-reading the
  live flags on the timer makes it self-heal within a second, and the shared entry point
  means the timer cannot flip the flag without also freezing the position.

Using Rust's old extrapolated value for rehydration was rejected: it would hide the snap by
skipping up to five seconds of audio that were never played.

## Why this is low priority

- Cosmetic. The audio was correct throughout; only the progress bar was briefly wrong.
- Self-correcting within one update after recovery.
- The exact 5 s residue was smaller than the 46 s stale-server jump that `b34889c`
  removed.

## Verification

Reproduce: play locally, sever the network long enough for `Connection to server closed`
(≈90 s), restore, and watch the log at the moment of resume. Before the fix there is a
`Position anchor: <larger> -> <smaller>` line whose difference can be exactly 5000 ms.
After the fix, the position should freeze while not ready and resume from Rust's raw
position without the backwards step.

## Related

- `b34889c` — readiness published only once the session is settled, which removed the much
  larger stale-server jump this residue was hiding behind.
- `1562456` — the rehydrating load that produces the authoritative position on resume.
