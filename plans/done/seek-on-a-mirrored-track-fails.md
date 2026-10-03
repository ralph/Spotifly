# A seek on a mirrored track with no device active fails

Status: **Done** 2026-10-03, verified live
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`takeOverMirror`,
`continueAsActive`, `handleClusterUpdate`, the transport commands)
Found: 2026-10-03, while doing the search field's focus fix

## Summary

Right after a launch, the bar shows the track Spotify last heard of, paused, mirrored "from no
active device". A click on the seek bar then said "Invalid state: No track loaded" in the bar,
and the position snapped back. Previous failed the same way, and Next did nothing.

## Problem

Measured on 2026-10-03 with the Debug build of main:

```
PlaybackViewModel] performSeek had no active device - running locally
PlaybackViewModel] performSeek failed: Invalid state: No track loaded
PlaybackViewModel] previous() failed: Invalid state: No track loaded
QueueService] Queue updated from the player: prev=0, current=0, next=0
```

With no device active, the transport commands run locally. `LibrespotClient.resume()` knew that
case: nothing loaded while the snapshot shows a track means the track is mirrored, and it took
it over (`takeOverState`, `continuePlayback`). The others didn't:

- **Seek** went straight to the audio pipeline, which had nothing loaded.
- **Previous** found no history and fell back to a seek to 0, which failed the same way, and its
  `publishQueue` replaced the mirrored queue with the empty local one.
- **Next** found an empty queue, rewound a context it didn't have, and released playback; the
  next cluster update mirrored the same track at the same position.
- **A double-click on a queue row** (`skip(toNext:)`) found the row in no local queue.

## What Spotify's clients do

The web player, in the same state (no device active, the track paused), measured 2026-10-03:

- **A seek** takes the track over, paused, at the new position, and the web player becomes the
  active device.
- **Previous**, 8 s into the track, takes it over and restarts it, paused.
- **Next** takes it over and plays the next track.

The web player plays through Spotify's `track-playback` service (its seek sent a
`PUT track-playback/v1/devices/<id>/state`), which makes it active on the server. A Connect
device's own PutState doesn't always: after this Mac's paused takeover, Spotify named it active
in five runs and not in one (`active device:` empty in the cluster, every 30 s heartbeat claiming
the role ignored). A transfer from this Mac to itself does make it active, paused, but a seek
would then wait for the transfer to come back before it could move the position.

## Solution

`takeOverMirror(positionMs:paused:)` takes the mirrored track over for any transport command
when nothing is loaded here, read and played as `resume()` did before:

- **Play** plays it from where the mirror showed it, as before.
- **A seek** loads it paused at the new position.
- **Previous** loads it paused at its start, which is the restart: nothing has played here to go
  back to.
- **Next** and **a queue row** load it paused at its start, then move on from it as from any
  track loaded here. That costs one load of a track they leave.

The takeover claims the role, as a handover does; `takeOver` and the mirror share that in
`continueAsActive`, which also lets the role go when the load fails.

When Spotify doesn't make the Mac active, it holds the track paused without the role. Nothing
stood such a track down: `handleClusterUpdate` stopped only a device that *had* been active, and
skips the mirror while something is loaded. Measured: the web player started playing and the bar
went on showing the Mac's paused track. Now a track held here paused gives way to any device the
cluster names active, as a paused active device does.

Not changed: this Mac's Previous goes back to the previous track whenever there is one, where the
web player restarts the track past its first seconds.

## Verification

- [x] Build, 627 unit tests and `swiftformat --lint`, exit 0, no warnings.
- [x] Live, Debug build of the branch, each from a fresh launch with no device active:
  - [x] A click on the seek bar at 2:30: the track loads paused at 150709 ms, the Mac becomes
        active, the web player shows 2:30 with "Wiedergabe über Spotifly". No error.
  - [x] Previous: the track loads paused at 0:00, active; the queue keeps its rows.
  - [x] Next: the next track plays (`65OiqqjrBoG1JvY3DDpWcL`), active.
  - [x] A double-click on "Sunset Bird" in the queue: it plays (`3JbR4uAoCFIEi2l8RKgdJH`).
  - [x] Play: takes the track over from 8568 ms and plays, as before.
- [x] The track held without the role, from a throwaway build that skipped the claim (never
      committed): the seek left the Mac `active=false` at 0:57; the web player's Play then made it
      active, and the Mac logged "letting go of the track held here paused", stopped, and mirrored
      the web player playing.
- [x] A handover still plays: in that run, `SPOTIFLY_DEBUG_TRANSFER_HERE_AFTER` pulled the web
      player's playback here, which took it over at 64923 ms and became active.
