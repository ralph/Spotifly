# The seek bar jumps because two clocks measure two different things

Status: **fixed 2026-08-14, confirmed at runtime.** Two runs, `../seek-after.log` and
`../seek-after2.log`: the jitter is gone, every dense run of snapshots now chains exactly
(`X` equals the previous `Y`) where before `X` ran ~1550 ms high every other line, and the
second run played 74 seconds untouched with **no** Connect snapshots and **no** drift
correction — the stretch that used to be corrected once a second. Both runs also caught the
first attempt at the abandoned-command case firing wrongly during a scrub; that is fixed
and is the one part still unconfirmed at runtime.
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

**Why later tracks look fine: confirmed 2026-08-14** from `../seek-after2.log`, and it is
the first of the two candidates. On a gapless transition librespot emits `Playing` for
track *n+1* at the instant the **decoder** switches — the same millisecond as the previous
track's `EndOfTrack`, while ~2 s of that track is still queued in the renderer:

```
07:27:15.655  PlayerEvent::EndOfTrack: …5aIfLbdgkbH7NbQryd1poB at 168398ms
07:27:15.655  PlayerEvent::Playing:    …3bz5lCYoTVdnhB2rCaMYKz at 0ms
```

Spirc anchors `nominal_start_time` there, and the Connect positions that follow are exact
wall-clock from it — 370 ms at `07:27:16.025`, 1197 ms at `07:27:16.852`. So from track two
onward **both clocks are ahead of the music by the buffer depth**, they agree with each
other, and nothing jitters because nothing disagrees.

That is worth stating plainly: this fix removes the *fight*, and it makes the first track
of a context honest. It does not make tracks two onward honest — they run about two
seconds ahead of what you hear, quietly and consistently. Only a real audible playhead
fixes that, which is the change listed under *Left standing*.

## Fix

**Give the drift correction two thresholds, because it is detecting two things.** The
decoder clock is not a rival measurement of the same quantity — it is an *upper bound* on
it. It is never behind the music, and it runs ahead by however much audio is buffered. So
the directions do not mean the same thing:

- The UI **ahead** of the decoder clock cannot happen while audio is flowing — the decoder
  is always in front. It means the Player has stopped producing while the Swift clock kept
  running, which is precisely the stall the check was written to catch. 500 ms.
- The UI **behind** the decoder clock is expected: that is the buffer. It says nothing,
  and correcting on it is the bug.
- Either direction is evidence while an **optimistic anchor** from a transport command has
  gone unconfirmed past its grace window, because then the display is somewhere playback
  never went — see below.

```swift
let unconfirmedFor = optimisticAnchorTime.map { CACurrentMediaTime() - $0 }
let correct = switch unconfirmedFor {
case let .some(elapsed) where elapsed < Self.optimisticAnchorGrace: false
case .some: abs(displayedLead) > Self.positionDisagreementMs
case .none: displayedLead > Self.positionDisagreementMs
}
```

The third case exists because the old symmetric check was quietly load-bearing for
something other than stall recovery. `seek(to:)`, `next` and `previous` anchor
**optimistically** (`PlaybackViewModel.swift:701`, `:722`, `:740`) so scrubbing feels
immediate. `performSeek` rolls that back only when the command could not be *issued*
(`:1176`); a command that was issued and then rejected reports nothing back, because
`SpotifyPlayer.seek` discards `spotifly_seek`'s result in a detached task
(`SpotifyPlayer.swift:1057`). The drift check was what noticed — a failed backward seek
from 100 s to 20 s left an 80-second gap that `abs(…) > 500` corrected on the next tick.

**That job is scoped by state, not by distance.** A first attempt used a second, larger
threshold — correct when the display sits more than 5 s *behind* Rust — and the
verification run showed exactly why that is wrong. Scrubbing backwards from 1:57 to 0:43,
the optimistic anchor legitimately sat 50 s behind Rust while the 150 ms seek debounce
ran, and the timer fired inside that window:

```
07:17:47.729  Position anchor: 67624 -> 117311   (Spirc still reporting the pre-seek position)
07:17:47.778  Drift correction: 66760 -> 117523  ← wrong: the seek had not been sent yet
07:17:48.431  Position anchor: 43745 -> 43596    (the seek lands, 25 ms after it is issued)
```

No scalar separates those cases: an abandoned command can leave a gap of any size, and a
legitimate in-flight one can leave a large gap. So the anchor carries a mark instead.
`anchorPosition(_:at:optimistic:)` records *when* a transport command wrote a promise, and
every other caller — all of which anchor something measured — clears the mark by writing.
The grace window then means "the command has not landed yet", and it re-stamps on each
drag update, so a long scrub extends it rather than outliving it. Past the window an
unconfirmed promise is one that was never kept, and any disagreement is evidence.

This is the command-scoped recovery the review asked for, without needing an
acknowledgement from Spirc that does not exist: `spotifly_seek`'s return says only that the
command reached Spirc's channel, not that Spirc applied it. "A measurement arrived" is the
acknowledgement, and it is already there. What remains unhandled is a command that is
rejected *and* followed by an unrelated authoritative update within the grace window; that
would clear the mark on a display that is still wrong, and it needs the real ack listed
below.

Why this shape:

- **It removes the fight without removing the check.** The stall recovery the comment at
  `PlaybackViewModel.swift:1404` describes — "a frozen value is precisely the signal that
  must pull a still-running Swift clock back to reality" — is entirely on the 500 ms side,
  and `plans/position-interpolation-runs-on-during-outage.md` confirms it at runtime: the
  correction that made this check load-bearing was `104403 -> 99403`, backwards.
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

- **transport commands are never acknowledged**, so an optimistic anchor is repaired by a
  threshold rather than by an answer. `spotifly_seek`, `spotifly_next` and
  `spotifly_previous` return a status that `SpotifyPlayer.swift:1039`, `:1048` and `:1057`
  throw away in a detached task — and exposing it would not be enough on its own, since it
  reports delivery to Spirc's channel rather than application by Spirc. A real ack, scoped
  to an outstanding command with a bounded timeout, would replace `abandonedCommandLagMs`
  entirely and is the follow-up this plan most wants;
- pausing reports the decoder position, so the bar steps ~2 s at pause
  (`rust/src/lib.rs:2343`);
- `freezePositionForDisconnect` freezes at the decoder position
  (`PlaybackViewModel.swift:1084`);
- resume-after-deactivation rehydrates from raw `POSITION_MS` (`rust/src/lib.rs:1998`,
  `:2753`), so it resumes ~2 s late;
- **gapless track boundaries**, now confirmed above: every track after a context's first
  runs ~2 s ahead of its own audio, because Spirc's epoch for it is the decoder switch
  rather than the moment it becomes audible. This is the largest of the four and the one
  that most wants the audible playhead.

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
