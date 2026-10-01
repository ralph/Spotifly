# After a handover, the seek bar can fall back to 0 while the track plays on

Status: **Open**, planned, not built. Seen by hand on 2026-10-01 while testing #135, which did not
cause it: the pieces date from #71 (2026-09-28) and e711146 (2026-08-14). The cause is read from
the log and the code; the fix is not tried yet.
Components: `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`playTrack`, `startDecoding`,
`tick`, `teardownAndGoIdle`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`
(`positionCache`, `handle(_:)`), `Spotifly/ViewModels/PlaybackViewModel.swift`
(`checkDriftAndSync`)
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

1. **The player's position is a cache fed only by the pipeline's ticks.**
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

A seek is not affected: it marks the anchor optimistic, and the drift check waits out its
one-second grace.

## Solution

Planned, not built. **Fix the stale cache, at its source:** the pipeline publishes the position
a load starts at, so the cache never claims 0 for a track that starts elsewhere.

- `playTrack` sends `.position(positionMs)` with its `.loading` announcement, and
  `startDecoding` sends the frame it starts from, in the same order as the state it publishes,
  since one stream carries both (`LibrespotClient.handle(_:)`).
- A unit test on the pipeline's events: a load at 65 s sends no `.position` below 65 s before
  its first tick.

**Optional, not needed for the fix:** correct a bar that is far behind the player, say more than
five seconds, as a safety net. The render buffer that justified leaving "behind" alone is under
a second, so a gap of seconds is never it. That direction has not been re-measured against the
current clock (`AudioRenderer.playedFrames`), which the comment in `checkDriftAndSync` says
too.

## Verification

Not run yet. When built:

- The unit test above.
- **Live, with a phone:** hand playback from the phone to the Mac mid-track five times or more.
  The bar should show the phone's position each time, and the log should have no
  `Drift correction: … -> 0`.
- **Live without a phone:** let the web player play, then launch the Debug build with
  `SPOTIFLY_DEBUG_TRANSFER_HERE_AFTER=<seconds>`. Repeat it a few times, since the race only
  hits about half the time.
