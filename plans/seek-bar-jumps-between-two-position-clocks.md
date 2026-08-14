# The seek bar jumps because two clocks measure two different things

Status: **diagnosed, not fixed.**
Components: `Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-08-14, from `../seek.log`

## Symptom

For the **first track** of a freshly started playlist or album, the seek bar jumps back
about 1.5 seconds and then catches up, over and over, for roughly the first 20–25 seconds
of the track. After that it runs smoothly. Subsequent tracks in the same context do not
show it.

## The two clocks

Spotifly reads playback position from two places that do not mean the same thing.

**The decoder clock** — `SpotifyPlayer.positionMs` → `spotifly_get_position_ms()` →
`POSITION_MS` in `rust/src/lib.rs`. Several player events write it (`rust/src/lib.rs:1795`
onwards: `Playing`, `Paused`, `Seeked`, `PositionCorrection`, `Loading`, `Stopped`,
`EndOfTrack`), but during untouched playback the one that keeps it moving is
`PlayerEvent::PositionChanged`, emitted every 200 ms because of
`position_update_interval: Some(Duration::from_millis(200))` (`rust/src/lib.rs:1671`).

That event carries `packet_position.position_ms` (`playback/src/player.rs:1470`): the
start timestamp of the packet the decoder has just pulled, sent at
`playback/src/player.rs:1543` — *before* that packet is handed to the sink at
`playback/src/player.rs:1564`. So it describes **audio decoded, not audio heard**, and it
is additionally stale by one packet plus up to one 200 ms reporting interval. librespot
says as much at `playback/src/player.rs:1489`:

```rust
// Only notify if we're skipped some packets *or* we are behind.
// If we're ahead it's probably due to a buffer of the backend
// and we're actually in time.
```

Our backend is exactly such a buffer. `AudioRenderer` lets the writer run up to
`maxBufferAheadSeconds = 2.0` ahead of real time (`AudioRenderer.swift:64`), across the
ring buffer and everything already enqueued on `AVSampleBufferAudioRenderer`.

**The Connect clock** — the `position_ms`/`timestamp_ms` pair on the playback-state
callback, from `connect_state.player.position_as_of_timestamp`. Spirc sets
`nominal_start_time = now - position` when `Playing` or `PositionCorrection` arrives
(`connect/src/spirc.rs:811`) and advances it by elapsed wall time on every outgoing
notification (`connect/src/spirc.rs:1896`, `connect/src/state.rs:442`). `PositionChanged`
is deliberately ignored (`connect/src/spirc.rs:881`).

Its epoch is when librespot starts the sink, not a measured speaker playhead —
`Playing` is emitted before the first packet is decoded (`playback/src/player.rs:1922`).
For the first track of a context that is within a buffer-fill of when the music starts,
which is close enough to be the honest clock here. It is not a physical playhead, and
nothing in this codebase has one.

## Evidence

Playback of the first track starts at `05:48:06.429`:

```
06.429 PlayerEvent::Playing: … at 0ms
```

Every Connect snapshot after that is exact wall-clock since that instant:

| wall clock | Connect position | elapsed since 06.429 |
|---|---|---|
| 09.350 | 2921 ms | 2921 ms |
| 10.409 | 3943 ms | 3980 ms |
| 29.445 | 23016 ms | 23016 ms |

Meanwhile the Swift anchor keeps being pulled to a value ~1.55 s higher, roughly once a
second, with no log line of its own:

```
07.096  Position anchor: 2422 -> 629    (true position 667 ms  → anchor was +1755)
08.348  Position anchor: 3472 -> 1881   (true position 1919 ms → anchor was +1553)
09.384  Position anchor: 4511 -> 2921   (true position 2955 ms → anchor was +1556)
10.412  Position anchor: 5537 -> 3943   (true position 3983 ms → anchor was +1554)
```

The `X ->` side of that line is the anchor as it stood *before* the Connect snapshot
arrived. Several `anchorPosition` calls do not log — initialisation, next, previous, seek,
resume (`PlaybackViewModel.swift:311`, `:711`, `:742`, `:770`) — but none of those can
fire repeatedly on a track nobody is touching. The only writer that can is
`checkDriftAndSync` (`PlaybackViewModel.swift:1407`), on a 1-second timer, and its cadence
and values match the log exactly:

```swift
if SpotifyPlayer.isActiveDevice {
    let rustPosition = SpotifyPlayer.positionMs
    let drift = abs(Int64(rustPosition) - Int64(interpolatedPositionMs))
    if drift > 500 {
        anchorPosition(rustPosition)
        didCorrectDrift = true
    }
}
```

The 1.55 s lead is far over the 500 ms threshold, so this fires on every tick.

The pause boundary measures the lead directly. At `05:48:29.44` both clocks describe the
same moment:

```
29.445  PlaybackState: position=23016ms            ← Connect clock, wall-clock derived
29.478  PlayerEvent::Paused: … at 25013ms          ← decoder clock
```

`25013 - 23016 = 1997 ms`, against a configured `maxBufferAheadSeconds` of `2.0`. That is
the whole bug in one subtraction. (Immediately after, Connect adopts the decoder value —
`Paused` overwrites `position_as_of_timestamp` at `connect/src/spirc.rs:839` — which is
why the log then shows `23016 -> 25013` and 25013 from there on. The 2.0 s is not a hard
ceiling either: an already-rendering `start()` re-arms the throttle without clearing the
buffer, `AudioRenderer.swift:345`.)

## Mechanism

1. The drift timer fires, reads the decoder clock, sees ~1.55 s of "drift", and jumps the
   anchor forward by that much.
2. A Connect snapshot arrives — during a context start these come every ~400 ms — and
   re-anchors to the honest position, so the bar drops back.
3. Repeat, about once a second. That is what "jumps back and catches up" looks like.

Step 2 happens that often because each `PUT /connect-state` is echoed back as a cluster
update, and `handle_cluster_update` sets `update_state = true` even for our own echo
(`connect/src/spirc.rs:1005`, marked `fixme` upstream), which PUTs again. That loop is
librespot's, and it is not the bug — it only sets the *rate* at which the honest clock
gets a chance to correct the dishonest one.

## Why it settles, and why only the first track

**Why it settles after ~20 s:** the Connect snapshots stop. In `seek.log` the last one
during playback is at `05:48:22`; after that the anchor is written only by the drift
timer, which then agrees with itself — once the anchor sits on the decoder clock, each
tick finds a drift of tens of milliseconds and does nothing. Settling is the fight ending,
not the disagreement being resolved: from `05:48:23` to the pause the displayed position
is ~1.6 s ahead of the music, quietly.

**What the end of the track can and cannot tell us.** Letting the first track run out
looked in sync. That is compatible with a 1.5 s lead rather than evidence against it. A
1.5 s error is ~0.7% of a 3½-minute track — one or two pixels of bar. And the decoder
clock converges at the end by construction: it stops at the track duration when the file
runs out while the audio drains for another ~1.5 s, and `clampedToTrack` pins the display
there. The predicted symptom is "bar reaches the end and sits there for a beat", which is
what "in sync" looks like. Only the log settles this.

**Why later tracks look fine:** unconfirmed. Two candidates, possibly both:

- On a gapless transition librespot emits `Playing` for track *n+1* when the **decoder**
  switches, while the previous track's audio is still draining. Spirc anchors
  `nominal_start_time` there, so the Connect clock picks up the same ~1.5 s lead as the
  decoder clock. Two clocks that agree do not fight — and both are ahead of the music.
- The Connect PUT/echo storm is a context-start phenomenon. Without frequent snapshots
  there is nothing to pull the anchor back, whatever the two clocks think.

The distinction matters for how much this fix is expected to achieve: under the first,
later tracks are *also* ~1.5 s ahead, and this fix does not change that.

## Fix

**Make the drift correction one-sided.** The decoder clock is not a rival measurement of
the same quantity — it is an *upper bound* on it. It is never behind the music, and it
runs ahead by however much audio is buffered. So the two directions carry different
information:

- The UI **behind** the decoder clock is expected buffering. It says nothing, and must not
  move the bar.
- The UI **ahead** of the decoder clock cannot happen while audio is flowing — the decoder
  is always in front. It means the Player has stopped producing while the Swift clock kept
  running, which is precisely the stall the check was written to catch.

```swift
// The Rust position is where the *decoder* is, which is ahead of what is audible by
// whatever AudioRenderer still has buffered. So only one direction is evidence: a
// display that has run past the decoder means the Player stopped while our clock did
// not. A display behind it is just the buffer, and correcting to it would jump the bar
// forward into audio nobody has heard yet.
let rustPosition = SpotifyPlayer.positionMs
let displayedLead = Int64(interpolatedPositionMs) - Int64(rustPosition)
if displayedLead > 500 {
    debugLog("PlaybackViewModel", "Drift correction: \(interpolatedPositionMs) -> \(rustPosition)")
    anchorPosition(rustPosition)
    didCorrectDrift = true
}
```

Why this shape:

- **It removes the fight without removing the check.** The stall recovery the comment at
  `PlaybackViewModel.swift:1404` describes — "a frozen value is precisely the signal that
  must pull a still-running Swift clock back to reality" — is entirely on the surviving
  side of the comparison.
- **The bar then stays on the Connect clock,** which is the honest one for the reported
  case, all the way to the end of the track. Nothing pulls it forward, so the ~1.6 s of
  silent lead after the snapshots stop goes away too.
- **Three lines, in the one place that was wrong.** No new measurement, no concurrency,
  no lifecycle epochs.

**Also: give the correction a log line.** It is currently the only anchor writer that can
fire repeatedly without logging, which is why this had to be inferred from the `X ->` side
of somebody else's message. It is the regression signal for this plan.

### Rejected: subtract the renderer's in-flight audio

The tempting fix is to make `SpotifyPlayer.positionMs` report the audible position by
subtracting what `AudioRenderer` still holds (ring buffer, plus `currentPTS` minus
`synchronizer.currentTime()`). It was rejected after review, because the subtraction is
only valid while audio flows uninterrupted, and the pipeline has several states where it
is not:

- **Seek does not flush the renderer.** `spotifly_seek` forwards `SetPosition`
  (`rust/src/lib.rs:3137`), spirc calls `player.seek` (`connect/src/spirc.rs:1577`), and
  `handle_command_seek` moves the decoder without touching the sink
  (`playback/src/player.rs:2234`). `ProxySink::clear_buffer` is reached only from
  `spotifly_clear_audio_buffer` and `spotifly_disconnect`. So after a seek the decoder
  jumps to the target while the buffer still holds pre-seek audio, and subtracting that
  buffer's duration from the new target puts the bar ~2 s behind where the user just
  dropped it.
- **`stop()` does not empty the pipeline** (`AudioRenderer.swift:377`) — it freezes the
  synchroniser and leaves the ring and `currentPTS` intact — so "in flight" means
  different things across pause, resume and route change.
- **Thread safety is not just `currentPTS`.** The synchroniser is itself replaced on
  `renderQueue` (`AudioRenderer.swift:463`), and a coherent snapshot has to take
  `renderQueue` *then* `bufferLock`, matching the order `start`/`stop`/`flush` already
  use. Reaching for `bufferLock` first and dispatching to `renderQueue` inverts it.
- **It would not fix the pause jump anyway** — that position arrives through
  `send_local_playback_state` (`rust/src/lib.rs:2343`), which never passes through the
  Swift getter.

A real audible playhead is a bigger, separate change: explicit epochs rebased on seek,
flush, route change, pause/resume and track transition, consumed by the local
playback-state callback and by Rust's rehydration as well as by the getter.

### Also rejected

- *Raise the 500 ms threshold above the buffer depth.* Disables the check for the stall it
  exists to catch, and 2.0 s is not a hard ceiling.
- *Interpolate in Rust.* Tried and reverted; the comment on `current_position_ms`
  (`rust/src/lib.rs:3098`) records the five-second snap-back it caused.
- *Shrink `maxBufferAheadSeconds`.* Reduces the error without removing it, and spends the
  dropout headroom the throttle exists to provide.

### Left standing, same root cause

Each of these is the decoder clock leaking into something user-visible, and each needs the
bigger change above:

- pausing reports the decoder position, so the bar steps ~2 s at pause
  (`rust/src/lib.rs:2343`);
- `freezePositionForDisconnect` freezes at the decoder position
  (`PlaybackViewModel.swift:1084`);
- resume-after-deactivation rehydrates from raw `POSITION_MS` (`rust/src/lib.rs:1998`,
  `:2753`), so it resumes ~2 s late;
- gapless track boundaries, if the first candidate above is what makes later tracks look
  fine.

## Verification

The fix is a number becoming correct, so verify by measurement, not by watching.

1. Build, launch with `RUST_LOG=librespot=debug,spotifly_rust=debug`, redirect to a log.
2. Start a **playlist from the top** — the first track is the reproducing case.
3. Let it play 30 seconds untouched, then pause. Do not judge by the bar: the quantity
   under test is ~1.5 s on a bar a few hundred pixels wide.
4. In the log, every `Position anchor: X -> Y` line during playback should now have `X`
   and `Y` within a few hundred milliseconds of each other, where before `X` ran ~1550 ms
   high once a second. The new `Drift correction:` line should not appear at all.
5. Seek mid-track and confirm the bar stays where it was dropped, with no `Drift
   correction:` line following.
6. Open question from *Why later tracks look fine*: let a track change happen naturally
   and check whether the Connect position for track two is still wall-clock-honest from
   its own `Playing` event, or has picked up the ~1.5 s lead.
