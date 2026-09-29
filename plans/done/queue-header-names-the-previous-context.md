# The queue names the previous album while a bare list plays

Status: **Done** 2026-09-29. Built and unit-tested; not yet seen in the running app; see
Verification.
Components: `Spotifly/Store/AppStore.swift` (`setQueue`), `Spotifly/Store/Services/QueueService.swift`
(`queueUpdate`, `fetchInitialPlaybackState`), `Spotifly/Views/QueueListView.swift`
(`contextInfo`, `playingFromText`)
Found: 2026-09-29, testing #84: a list of three tracks sent to the Mac played under the header
"Wiedergabe von „Alive“", the album played before it.

## Summary

A list of tracks with no album or playlist behind it has an empty context uri. `AppStore.setQueue`
kept the previous one when it was handed an empty uri, so the queue's header went on naming the
album or playlist that played before, and linked to it. An empty uri now clears the context, and
a header with no context to name says only where the music plays.

## Problem

- `setQueue` updated `queue.contextUri` only if the uri was "non-nil and non-empty", a rule from
  the Web API days, when an answer could leave the context out.
- The player now always says what it plays from, and an empty uri means a bare list: Play Tracks
  under search, and since #84 a list sent from another device.
- So `QueueListView.contextInfo` found the old album in the store and showed it as "playing from",
  with a link to it.

### Callers, checked as the plan asked

No caller passes an empty uri meaning "unknown":

- `QueueService.handleQueueUpdate` passes the published `QueueState.contextUri`. The local queue
  publishes `PlaybackQueue.contextUri`, which `play` sets to the context, to the track's own uri
  for a single track, and to "" only for a bare list. The mirror of another device publishes the
  cluster's `context_uri`.
- `QueueService.fetchInitialPlaybackState` passed **no** uri at all, although the snapshot it
  reads has one. So the first queue after launch named no context, whatever was playing, until
  the next update. It passes the snapshot's now.

## Solution

- `setQueue` takes the context uri as a required `String` and stores an empty one as nil.
  `Queue.contextUri` says nil means a bare list.
- `QueueService.queueUpdate` returns the snapshot's context uri with the entries, and
  `fetchInitialPlaybackState` passes it on.
- The header says "Playing from "Alive" on Mac" when it knows the context's name, and "Playing on
  Mac" when it does not (de "Wiedergabe auf", fr "Lecture sur"). Before, a context with no name in
  the store read "Playing from "Queue"", with the word Queue quoted as if it were the name; a bare
  list now reads the same way as such a context.

A side effect in `PlaybackViewModel.play(queueRow:)`: a previous row played on another device
sends `store.queue.contextUri ?? uri` as the context. For a bare list that is now the track alone,
where it used to name the old album.

## Verification

- [x] Unit tests: a bare list after an album leaves `contextUri` nil, and the initial snapshot
      carries its context through `queueUpdate`.
- [x] Build, 443 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: play an album, then Play Tracks under Search's "Show all tracks". The queue's header
      says "Wiedergabe auf …" with no album named and no link.
- [ ] Live: play an album again. The header names it, and the name links to it.
- [ ] Live: relaunch while an album plays. The header names the album at once.
