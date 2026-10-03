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
- **Next** and **a row ahead in the queue** load it paused at its start, then move on from it as
  from any track loaded here, queued and autoplay rows included. That costs one load of a track
  they leave; measured, 80 ms passed before Next's own track started loading.
- **A row before it in the queue** plays the context, or the list, from that row
  (`TransferState.startingOver`): none of the mirrored rows played here, so none is in the
  history. Another device is asked the same (`PlaybackViewModel.play(queueRow:)`).

The takeover claims the role, as a handover does; `takeOver` and the mirror share that in
`continueAsActive`, which also lets the role go when the load fails. A command that comes while a
takeover loads waits for it and acts on the track it loaded, so a double-click on the queue's
current row, a Play and a seek to 0, takes the track over once (from the review).

When Spotify doesn't make the Mac active, it holds the track paused without the role. Nothing
stood such a track down: `handleClusterUpdate` stopped only a device that *had* been active, and
skips the mirror while something is loaded. Measured: the web player started playing and the bar
went on showing the Mac's paused track. Now a track held here paused gives way to a device the
cluster names active and playing, as a paused active device does. Only playing: a device that is
named but paused might be the sender of a paused handover still loading here.

Left for `plans/open/shuffle-and-queue-on-a-mirrored-track.md`: Shuffle and Add to Queue still act
on the empty local queue with no device active.

Not changed here: this Mac's Previous went back to the previous track whenever there was one,
where the web player restarts the track past its first seconds. Done since in
`plans/done/previous-restarts-past-three-seconds.md`.

## Verification

- [x] Build, 629 unit tests and `swiftformat --lint`, exit 0, no warnings. `MirroredQueueTests`
      cover `startingOver`, for a context and for a bare list.
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
- [x] After the review's changes, the same build:
  - [x] A double-click on the queue's current row: one takeover, playing, then the seek to 0
        on the loaded track; it plays from the start.
  - [x] A double-click on "Sunset Bird", a row before the current one: it plays from 0:00, and
        the queue lists the rows after it. It used to fail with "no longer in the queue".
  - [x] A paused handover: the web player paused at 0:53, pulled here; taken over paused at
        53391 ms, active, and not let go.
  - [x] A seek: loads paused at 133154 ms, active.
