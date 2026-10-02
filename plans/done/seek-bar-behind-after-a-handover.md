# After a handover, the seek bar can fall back to 0 while the track plays on

Status: **Done** 2026-10-01. Seen by hand while testing #135, which did not cause it: the pieces
date from #71 (2026-09-28) and e711146 (2026-08-14). Reproduced and seen fixed live with a
drift check made to run every 50 ms; see Verification. No unit test: the client is a singleton.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`positionCache`,
`publishPlaybackState`), `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift`
(`loadingPositionMs`, `currentPositionMs`), `Spotifly/ViewModels/PlaybackViewModel.swift`
(`checkDriftAndSync`, `syncPositionAnchor`)
Found: 2026-10-01, handing playback from a phone back to the Mac

## Summary

Taking over a track at a position (a handover from another device, here at about 1:05) plays
the audio from the right place, but the seek bar can jump to 0:00 a moment later and then
stay that far behind the audio for the rest of the track. The next track puts it right. The
phone showed the right position throughout. The drift check reads the player's position before
the pipeline has published one for the new load, and gets the 0 it published when the Mac
stopped.

## Problem

### Seen

A phone took playback from the Mac and gave it back twice, in "Columbia (Live at Knebworth)".
Both times the log (the Debug build's stderr, kept as `foo.log` for the test) shows the same
sequence:

```
19:16:21.993 LibrespotClient] Taking over spotify:track:5fHlj… at 65609ms (reported 52396ms at …)
19:16:22.037 AudioPipeline] Playing spotify:track:5fHlj… at 65609ms
19:16:22.043 PlaybackViewModel] Position anchor: 52396 -> 65609 (timestamp was 7ms ago)
19:16:22.282 AudioRenderer] Restarted
19:16:22.288 PlaybackViewModel] Position anchor: 65609 -> 65609 (timestamp was 6ms ago)
19:16:22.359 PlaybackViewModel] Drift correction: 65685 -> 0
```

The first handback, at 23.4 s, logged `Drift correction: 23475 -> 0` 75 ms after the renderer
restarted, the same way. Nothing moved the anchor again until the next track started, nearly
four minutes later (`Position anchor: 0 -> 104` at 19:20:04).

### Why

1. **The player's position was a cache fed only by the pipeline's ticks.**
   `SpotifyPlayer.positionMs` reads `LibrespotClient.positionCache`, which only `.position`
   events set. The pipeline sends one every 250 ms while it plays (`tick`), and a 0 when it
   goes idle (`teardownAndGoIdle`).
2. **Stopping for another device sets it to 0, and it stays there.** When the phone took
   playback, the Mac's pipeline stopped and published 0. While the Mac only mirrors the phone,
   nothing else writes the cache.
3. **A load at an offset leaves the 0 in place.** The takeover anchors the bar at 65609 from
   the `.loading` state, but the cache still says 0 until the first tick. That tick comes 250 ms
   after `startDecoding` starts the position timer, about half a second after the anchor.
4. **The drift check believes it.** `checkDriftAndSync` runs once a second while this Mac is
   the active device. Inside that half second it saw the bar 65 s ahead of a player at 0,
   which reads as a stall (more than `positionDisagreementMs`, 500 ms), and anchored the bar at 0.
5. **And never takes it back.** A bar behind the player is left alone by design, since that gap
   used to be the render buffer (e711146). So the bar runs on from 0 while the audio runs on
   from 65 s, until a track change re-anchors it.

The window is about half of each one-second drift tick, so roughly every other handover at a
position should show it; both here did.

### What else starts at an offset

The same window opens wherever a load starts elsewhere than 0 after the cache was zeroed or
left at another track's position:
- a handover (`takeOver`);
- Play on mirrored playback (`resume()` taking it over);
- the recovery's reload after sleep (`Recovery reloading … at …ms`).

A seek had the same window: its `.playing` or `.paused` state anchors the bar as a
measurement, which ends the optimistic grace, while the cache still held the old position until
a tick, a quarter second later, or after the resume of a paused seek.

## Solution

**The cache takes every position local playback publishes.** `publishPlaybackState` is the one
place a local position goes out, the `.loading` of a load at an offset, the `.playing` and
`.paused` after a load or a seek, and the reload after sleep among them, and the bar anchors at
what it publishes. It now writes the same position into `positionCache`, so the cache and the
bar agree from the moment a load is announced, rather than from the first tick a quarter second
after the decode starts. The ticks go on feeding it as before. Mirrored playback does not go
through it, and the drift check does not run while this Mac only mirrors.

That also covers seeks, whose state now writes the target into the cache with it, playing or
paused.

**The pipeline knows where a load starts, too.** Its own answer, `currentPositionMs()`, said 0
from `.loading` until the decode started, since the teardown before a load zeroes the sink's
clock. Nothing in the reported case read it then, but a shuffle or repeat toggled during a
handover's download published the track at 0 (`publishPlaybackStateRefresh`), now into the cache
as well, and sleep then would have kept it as paused at 0 for the wake to reload from. The
pipeline now keeps the position a `.loading` announces (`loadingPositionMs`) until the decode
starts, the load fails or a teardown comes, and answers with it.

**Considered and not done:**
- The pipeline sending `.position` with `.loading` and from `startDecoding`: two more writers of
  the cache, where `publishPlaybackState` already writes every local position.
- **A cache that can say "nothing loaded here".** It is a bare position, and a stop writes 0, so
  "nothing loaded" reads as 0:00. A handover reports this Mac active before its load is
  announced, so a cluster update naming it in between would let the drift check compare the
  mirrored bar with that 0 and correct it, until the `.loading` a moment later anchors it again:
  a flash, not the stuck bar, and not seen. An optional cache, nil after a stop, would end it,
  and with it the "skip 0" in `syncPositionAnchor`.
- Correcting a bar far behind the player as a safety net: with the cache right, nothing put it
  there, and the render buffer reasoning for leaving "behind" alone (e711146) is unchanged.

## Verification

- [x] **Reproduced live without the fix** (2026-10-01), a throwaway build whose drift check ran
      every 50 ms, so that it always lands in the window: the web player played "Not Bad for New
      Jersey", and `SPOTIFLY_DEBUG_TRANSFER_HERE_AFTER=15` pulled it here. `Taking over … at
      30433ms`, then `Drift correction: 30548 -> 0` and again `30542 -> 0`.
- [x] **Fixed, the same throwaway with the fix:** `Taking over … at 29854ms`, the anchor at 29854,
      and no drift correction in the 12 s watched. Again with the pipeline's `loadingPositionMs`
      added: `Taking over … at 30431ms`, the anchor at 30431, then 30432 once the decoder opened,
      and no drift correction in 12 s.
- [x] Build, unit tests and the lint.
- [ ] By hand with a phone, as found: hand playback back mid-track a few times and watch the bar.
