# Audio throttle anchor is not reset when the player is rebuilt, so playback races after a reconnect

Status: **fixed 2026-07-30** — options 1 and 2 below, both applied. Kept as a record.
Component: `spotifly-code/Spotifly/AudioRenderer.swift`, `spotifly-code/rust/src/proxy_sink.rs`
Found: 2026-07-30, while verifying reconnect behavior against official librespot

## Resolution

Both small fixes were applied together, since they address different halves:

- **Option 2 (cause).** `ProxySink::notify_player_gone()` sends `AUDIO_CONTROL_STOP` from
  both teardown paths (`do_reconnect_cleanup`, `spotifly_cleanup`). Dropping the `Player`
  never ran `Sink::stop`, so the renderer was left believing it was rendering for a player
  that no longer existed. With this, `isRendering` is false by the time the rebuilt player
  starts, and the normal reset path runs.
- **Option 1 (belt and braces).** `AudioRenderer.start()` now re-anchors `writeStartTime`
  and `totalSamplesWritten` even when it returns early because it is already rendering.
  Deliberately *only* the anchor — a full pipeline reset mid-playback would glitch the
  audio, and re-anchoring cannot, since it touches neither the ring buffer nor its
  contents. This covers any future path that tears down a player without notifying.

Option 3 (windowed throttle) was **not** done. It is the more robust design, but with the
cause fixed and a guard behind it, the extra change was not worth it.

Verification is the reproduction below: after a reconnect, `EndOfTrack` should now land
near the track length rather than tens of seconds short.

---

## Symptom

After a reconnect that rebuilds the player, the decoder races through the remainder of the
track at roughly 40× real time. Playback itself sounds continuous — the audio renderer
still plays its buffer out in real time — but everything derived from the *decoder's*
position runs far ahead of what the user is hearing:

- `PlayerEvent::EndOfTrack` fires ~40 seconds before the audio actually ends.
- Spirc advances to the next track at that moment, so the Connect state and any remote
  device see the wrong track.
- The reported position, and therefore the progress bar, jumps ahead.

Measured in the 2026-07-30 17:36 run:

```text
17:36:45.663  PlayerEvent::Playing at 115577ms       # resume after reconnect
17:36:46.619  PlayerEvent::EndOfTrack at 155766ms    # 40189ms of content in 956ms wall
17:36:46.619  command=Load(5eAH…, true, 0)           # next track starts, ~40s early
```

Track length was 166000 ms, so `EndOfTrack` also fired ~10 s short of the true end.

## Root cause

`AudioRenderer` throttles the writer against wall clock, because
`AVSampleBufferAudioRenderer` accepts data eagerly and provides no real-time back-pressure
of its own. `AudioRenderer.swift:209-215`:

```swift
let audioDuration = Double(samplesWritten) / (Self.sampleRate * Double(Self.channelCount))
let elapsed = ProcessInfo.processInfo.systemUptime - startTime
let ahead = audioDuration - elapsed
if ahead > Self.maxBufferAheadSeconds {          // 2.0
    Thread.sleep(forTimeInterval: ahead - Self.maxBufferAheadSeconds)
}
```

This is **cumulative** against an anchor (`writeStartTime`, `totalSamplesWritten`) that is
reset in `resetRingBuffer()` (`AudioRenderer.swift:446`), reached via `resetAudioPipeline()`
from `start()` and `stop()`.

`start()` begins with a guard (`AudioRenderer.swift:331`):

```swift
guard !isRendering else {
    bufferLock.unlock()
    return          // <-- returns before resetAudioPipeline()
}
```

So if `isRendering` is still `true`, `start()` is a no-op and **the anchor is never reset**.

That is exactly what happens on reconnect. The old `Player` is dropped during
`do_reconnect_cleanup` without `Sink::stop()` ever being called, so no
`AUDIO_CONTROL_STOP` reaches Swift and `isRendering` stays `true`. When the rebuilt player
starts, `ProxySink::start()` sends `AUDIO_CONTROL_START`, `AudioRenderer.start()` returns
early, and the throttle is still measuring against an anchor set before the outage.

By then `elapsed` includes the entire outage (~165 s in this run) while `audioDuration`
counts only audio actually written. `ahead` is hugely negative, the throttle never sleeps,
and the writer runs flat out until it has "caught up" to the accumulated deficit.

### Evidence from the log

The whole 788-line run contains exactly two `AudioRenderer` lines and no `ProxySink: Stop`:

```text
17:33:49.627  AudioRenderer] Initialized (44100Hz, 2ch, Float32)
17:34:00.651  ProxySink: Start
17:34:00.652  AudioRenderer] Started playback        # first start: anchor reset
…            (no ProxySink: Stop anywhere)
17:36:45.663  ProxySink: Start                        # after rebuild
…            (no "Started playback" — start() returned early)
```

The missing second `Started playback` is the guard firing. That is the whole bug.

The code comment at `AudioRenderer.swift:342` already refers to a previous "28x speed bug"
fixed by clearing stale state on start — this is the same failure mode returning through a
path where `start()` declines to do that clearing.

## Notes on scope

- The throttle design itself is sound; only the reset path is incomplete.
- Not introduced by the reconnect rewrite: the `start()` guard and the missing
  `Sink::stop()` on teardown both predate it. What changed is that the rebuild path is now
  the *only* recovery strategy, so it is reached on every outage instead of rarely.
- Position bookkeeping is *not* at fault. `POSITION_MS` follows `PlayerEvent::PositionChanged`
  (`rust/src/lib.rs:1278`, deliberately unlogged, it is high-frequency), which faithfully
  reports where the decoder is. The decoder really is 40 s ahead.

## Fix options

Roughly in order of preference:

1. **Reset the anchor on start even when already rendering.** Move the anchor reset ahead
   of the `isRendering` guard, or have `start()` re-anchor unconditionally. Smallest change,
   and directly targets the failure.
2. **Emit a stop on teardown.** Have the Rust side send `AUDIO_CONTROL_STOP` when a player
   is torn down (`do_reconnect_cleanup` / `spotifly_cleanup`), so `isRendering` is false by
   the time the rebuilt player starts. Also correct on its own terms — the renderer is
   currently left believing it is rendering for a player that no longer exists.
3. **Make the throttle windowed rather than cumulative.** Measure "ahead" over a recent
   window instead of since an anchor, so an idle gap cannot bank credit at all. Most robust
   against any future path that forgets to re-anchor, but the largest change.

1 and 2 are complementary and both small; doing both would be reasonable.

## Verification

Reproduce: play a track, sever the network long enough for `Connection to server closed`
(≈90 s), restore, and let the resumed track run. Watch for
`PlayerEvent::EndOfTrack: … at Nms` — before the fix, N lands far short of the track length
and arrives seconds after the resume rather than minutes.

Also worth checking after any fix, since they exercise the same reset path:

- Ordinary track-to-track transitions (no reconnect) still pace correctly.
- Seeking within a track does not race.
- Pause/resume does not race.
- The first track after app start still plays at normal speed.

Adding a `debugLog` to the `start()` early-return would make this diagnosable directly
rather than by inferring from the absence of a log line.

## Related

- Reconnect rewrite and the rehydration load that exposes this: commits `2e094c8`,
  `1562456`.
- `EndOfTrack` logging that made it measurable: commit `659e979`.
- Unrelated upstream librespot issue found in the same testing:
  [librespot/upstream-transient-load-failure.md](librespot/upstream-transient-load-failure.md).
