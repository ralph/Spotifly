# The seek bar jumps because two clocks measure two different things

Status: **diagnosed, not fixed.**
Components: `Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/SpotifyPlayer.swift`,
`Spotifly/AudioRenderer.swift`
Found: 2026-08-14, from `../seek.log`

## Symptom

For the **first track** of a freshly started playlist or album, the seek bar jumps back
about 1.5 seconds and then catches up, over and over, for roughly the first 20–25 seconds
of the track. After that it runs smoothly. Subsequent tracks in the same context do not
show it.

## The two clocks

Spotifly reads playback position from two places that do not mean the same thing.

**The decoder clock** — `SpotifyPlayer.positionMs` → `spotifly_get_position_ms()` →
`POSITION_MS` in `rust/src/lib.rs`, fed by `PlayerEvent::PositionChanged` every 200ms
(`position_update_interval: Some(Duration::from_millis(200))`, `rust/src/lib.rs:1671`).

That event carries `new_stream_position_ms`, which is the position of the packet the
decoder just handed to the sink — **audio written, not audio heard.** librespot says so
itself, at `playback/src/player.rs:1489`:

```rust
// Only notify if we're skipped some packets *or* we are behind.
// If we're ahead it's probably due to a buffer of the backend
// and we're actually in time.
```

Our backend is exactly such a buffer. `AudioRenderer` lets the writer run up to
`maxBufferAheadSeconds = 2.0` ahead of real time (`AudioRenderer.swift:64`), across the
ring buffer and everything already enqueued on `AVSampleBufferAudioRenderer`. So the
decoder clock reads up to two seconds ahead of the music.

**The Connect clock** — the `position_ms`/`timestamp_ms` pair on the playback-state
callback, which comes from `connect_state.player.position_as_of_timestamp`. Spirc sets
`nominal_start_time = now - position` when the `Playing` event arrives and then reports
wall-clock elapsed since (`connect/src/spirc.rs:812`). For the first track of a context
that instant is when the music actually starts, so this clock is honest.

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
arrived. Only one writer sets the anchor without logging — `checkDriftAndSync`
(`PlaybackViewModel.swift:1407`), which runs on a 1-second timer:

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

The 1.55 s lead is far over the 500 ms threshold, so this fires every single tick.

The pause boundary measures the lead directly. At `05:48:29.44` both clocks report the
same moment:

```
29.478  PlayerEvent::Paused: … at 25013ms          ← decoder clock
29.445  PlaybackState: position=23016ms            ← Connect clock
```

`25013 - 23016 = 1997 ms`, against a configured `maxBufferAheadSeconds` of `2.0`. That is
the whole bug in one subtraction.

## Mechanism

1. The drift timer fires, reads the decoder clock, sees ~1.55 s of "drift", and jumps the
   anchor forward by that much.
2. A Connect snapshot arrives (during a context start these come every ~400 ms) and
   re-anchors to the honest position — the bar drops back.
3. Repeat, about once a second, which is what "jumps back and catches up" looks like.

Step 2 happens that often because each `PUT /connect-state` is echoed back as a cluster
update, and `handle_cluster_update` sets `update_state = true` for our own echo
(`connect/src/spirc.rs:1005`, marked `fixme` upstream), which PUTs again. That loop is
librespot's, and it is not the bug — it only sets the *rate* at which the honest clock
gets a chance to correct the dishonest one.

## Why it settles, and why only the first track

**Why it settles after ~20 s:** the Connect snapshots stop. In `seek.log` the last one
during playback is at `05:48:22`; after that the anchor is written only by the drift
timer, which agrees with itself — once the anchor sits on the decoder clock, each
subsequent tick finds a drift of tens of milliseconds and does nothing. Settling is the
fight ending, not the disagreement being resolved: from `05:48:23` to the pause at
`05:48:29` the displayed position is ~1.6 s ahead of the music, quietly.

**What the end of the track can and cannot tell us.** Letting the first track run out
looked in sync. That is compatible with a 1.5 s lead rather than evidence against it, for
two reasons. A 1.5 s error is about 0.7% of a 3½-minute track — one or two pixels of bar,
below what an eye can resolve. And the decoder clock *converges* at the end by
construction: it stops at the track duration when the file runs out, while the audio
drains for another ~1.5 s, and `clampedToTrack` pins the display there. The predicted
symptom is therefore "bar reaches the end and sits there for a beat", which is exactly
what "in sync" looks like. Only the log settles this — hence the verification below.

**Why later tracks look fine:** unconfirmed, and worth confirming before the fix is
called complete. Two candidates, and both may hold:

- On a gapless transition librespot emits `Playing` for track *n+1* when the **decoder**
  switches, while the previous track's audio is still draining. Spirc anchors
  `nominal_start_time` there, so the Connect clock is then wrong by the same ~1.5 s as the
  decoder clock. Two clocks that agree do not fight — and both are ahead of the music.
- The Connect PUT/echo storm is a context-start phenomenon. Without frequent snapshots
  there is nothing to pull the anchor back, whatever the two clocks think.

The distinction matters: under the first, later tracks are *also* wrong, just quietly.

## Fix

**Report the audible position, not the decoded one.** `AudioRenderer` knows exactly how
much audio is in flight, so `SpotifyPlayer.positionMs` can subtract it:

```swift
static var positionMs: UInt32 {
    let decoded = spotifly_get_position_ms()
    let inFlight = audioRenderer.inFlightMs
    return decoded > inFlight ? decoded - inFlight : 0
}
```

with, in `AudioRenderer`:

```swift
/// Audio handed to the pipeline but not yet heard: what still sits in the ring
/// buffer, plus what is enqueued on the renderer ahead of the synchroniser.
var inFlightMs: UInt32 { … }
```

measured as `availableSamples / (sampleRate * channelCount)` plus
`currentPTS - synchronizer.currentTime()`.

Three properties make this the right shape:

- **It is derived, not assumed.** It reads live pipeline state rather than a constant, so
  a flush drops it to zero on its own and a seek needs no special case.
- **It corrects at the boundary.** All three readers of `SpotifyPlayer.positionMs`
  (`checkDriftAndSync`, `syncPositionAnchor`, the frozen-position path at
  `PlaybackViewModel.swift:1084`) want "where is the music now", so one getter serves all
  of them and nothing downstream changes.
- **It fixes the disagreement rather than muting it.** The bar ends up on the audible
  position on every track, not just on the first one where the Connect clock happened to
  be honest.

`audioRenderer` is already a file-scope value in `SpotifyPlayer.swift:291`, so no new
wiring is needed. `currentPTS` is mutated on `renderQueue` and would be read from the
caller's thread, so the implementation must publish it under `bufferLock` alongside the
ring-buffer indices rather than reading it unsynchronised.

**Also: give the drift correction a log line.** Every other writer of the anchor logs;
this one does not, which is why the second clock was invisible in the log and had to be
inferred from the `X ->` side of somebody else's message. It is one line, and it is the
regression signal for this plan.

### Rejected alternatives

- *Suppress drift correction while a recent Connect snapshot exists.* Stops the jumping
  and leaves the bar ahead of the audio, on every track, permanently. Treats the visible
  half of the symptom.
- *Raise the 500 ms drift threshold above the buffer depth.* Same objection, and it
  disables the drift check for the case it exists to catch.
- *Interpolate in Rust.* Already tried and reverted; the comment on `current_position_ms`
  (`rust/src/lib.rs:3098`) records the five-second snap-back it caused.
- *Shrink `maxBufferAheadSeconds`.* Reduces the error without removing it, and trades it
  against the dropout headroom the throttle exists to provide.

### Out of scope, same root cause

`send_local_playback_state` reports the decoder clock too, so pausing shows a ~2 s jump of
its own (`25013` then `23016`, above). The correction above does not reach it: the pause
path stops the renderer *before* the `Paused` event is emitted (`ProxySink: Stop` at
`29.445`, `Stopped playback` at `29.478`, `Paused … 25013ms` at `29.478`), so by the time
the position is reported there is no in-flight audio left to subtract. It needs a
last-known-audible position carried across the stop, which is a different change with a
different risk profile. Separate commit, after this one lands.

## Verification

The fix is a number becoming correct, so verify by measurement, not by watching:

1. Build, launch with `RUST_LOG=librespot=debug,spotifly_rust=debug`, redirect to a log.
2. Start a **playlist from the top** (the first track is the reproducing case).
3. Let it play 30 seconds untouched, then pause. Do not judge by watching the bar: the
   quantity under test is ~1.5 s on a bar a few hundred pixels wide.
4. In the log, compare each `Position anchor:` line's `X ->` side against the Connect
   position on the same line. Before the fix they diverge by ~1550 ms once a second;
   after it they should agree within the 500 ms threshold, and the drift correction's new
   log line should be rare rather than once a second.
5. Confirm the open question from *Why later tracks look fine*: let the track change
   naturally and check whether the Connect clock is still wall-clock-honest for track two,
   or has picked up the same ~1.5 s lead.
