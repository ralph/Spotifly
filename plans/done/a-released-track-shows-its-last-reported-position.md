# A track this Mac lets go of jumps back to its last reported position

Status: **Done** (2026-10-03)
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirror`, `playbackFailed`,
`releasePlayback`), `Spotifly/SwiftLibrespot/Connect/SpircController.swift` (`release(stopped:)`, `stopped(_:atMs:)`),
`Spotifly/SwiftLibrespot/Proto/TransferState.swift` (`positionAsOfTimestamp`)
Found: 2026-10-03, verifying `plans/done/playback-view-model-mirrors-the-player.md`

## Summary

When this Mac stops playing over an error, the bar keeps the track, stopped where it was. Then the
cluster's answer to the release arrives with no active device, and the bar mirrors this Mac's own
last report from there: the position that report gave, without the time played since.

Seen with a throwaway that called `playbackFailed` 10.2 s into a track: the bar stopped at
10188 ms, and 34 ms later the mirror anchored it at 3894 ms, the position of the report this Mac
had sent 6.3 s earlier, when shuffle was switched on.

## Problem

`mirror(_:deviceActive:)` builds the state with `positionMs: remote.positionAsOfTimestamp` and
the report's timestamp. With no device active it says not playing, so the view model anchors
that raw position and does not run it on, though the report said playing and Spotify would
count on from its timestamp. For a device that has gone, that is right: it stopped at some
unknown moment. For this Mac's own release, it stopped now, and the client knows where.

The client reports to the cluster on changes only, so the gap is as long as the time since the
last change: minutes, into a track.

## Solution

The first: what librespot's `handle_disconnect` does, and what this Mac's own shutdown already
did (`SpircController.shutdown(stopped:)`). Letting go of playback now reports the track
paused where it had got to, while still the active device, and then stands down
(`SpircController.release(stopped:)`); the computation the shutdown had inline is
`SpircController.stopped(_:atMs:)`, which both use. `LibrespotClient.releasePlayback` takes the
local state as it was before it was cleared: a failed load (`playbackFailed`) and a context with
nothing left to play pass theirs, and a handover that failed to load passes none, since a load
that failed there has released with its own.

The mirror is unchanged: for a device that has gone, the raw position is still right.

## Verification

With throwaways, not committed: local playback muted, shuffle switched on 3 s in so the
cluster's last report came from then, and `playbackFailed` called 10 s in.

- **Before** (2026-10-03, earlier): the bar stopped at 10188 ms, and the cluster's answer 34 ms
  later anchored it at 3894 ms, the report from 6.3 s before.
- **After:** `PutState playerStateChanged active=true: paused 10079ms`, then `active=false: no
  player state`; the cluster's answer mirrored the track paused at 10079 ms, and the bar stayed
  there for the next seven samples. The model's last report had said 2837 ms.
- Unit tests for `stopped(_:atMs:)`: a playing track runs on by the time since its report, a
  paused one does not, neither past the track's end, and one of unknown length by the time
  alone. 621 tests pass.
