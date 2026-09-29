# A double-click in the queue starts its context over

Status: **Open**, not planned. Recorded 2026-09-29 while landing #79.
Components: `Spotifly/Views/QueueListView.swift`, `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`, `Spotifly/ViewModels/PlaybackViewModel.swift`,
`Spotifly/PartnerAPI/ConnectState.swift`
Found: 2026-09-29, Step 3 of `plans/done/clicked-row-plays-another-track.md`

## Summary

Since #79, a double-click on a queue row plays the track clicked. It does that by playing the
queue's context again, starting at the track. The queue it had is gone: the history, the
tracks queued by hand, the shuffle order. The queue view should jump to the row instead, the
way Spotify's own queue does, and keep everything else.

## Problem

`QueueListView` plays `store.queue.contextUri` with the row's track, and `LibrespotClient.play`
resolves the context again and builds a new `PlaybackQueue` from it:

- **The history goes.** `setContext` clears it, so Previous has nowhere to go.
- **Tracks queued by hand go.** They are not in the context. Double-clicking one plays it,
  then the context from its first track. The others are dropped.
- **The shuffle order is drawn again.** `setContext` reshuffles.
- **Copies are a guess.** A queue row's index counts queue rows, not context tracks, so for a
  track the context holds twice, `PlaybackQueue.start` picks the copy nearest a number that
  means something else.

A remote device is the same: the view sends a `play` command, and the device resolves the
context again.

### Starting by uid

Moved here from #79's plan. The resolver's tracks carry a `uid`, the same uid
`fetchPlaylistContents` gives a playlist item (`"uid":"87ced089511bc3c325f3"` for the first
Liked Songs track on 2026-09-29), and `SPClient.parseContextReport` keeps only the uri. Starting
by uid would pick the right copy of a duplicated playlist track with no guessing, wherever the
view has a uid. The playlist rows have one; the queue rows would need one kept for them.

## Solution

Not planned yet. A likely shape:

1. Locally, a skip on `PlaybackQueue` to a row as the view counts rows: into the history, into
   the tracks queued by hand, or forward in the context. It moves `currentIndex`, trims the
   history or the user queue the way Spotify does, and starts that track with `loadAndPlay`,
   without resolving anything.
2. Remotely, Connect's `skip_next` takes a `track` with a `uri` and a `uid`, which is how the
   web player jumps within a remote queue. Measure what it sends first.
3. Keep uids on queue rows, from the resolver and from the cluster's `ProvidedTrack.uid`, so the
   skip names an exact row.

## Verification

Not defined yet. What shows the problem today: queue two tracks by hand, then double-click a
context row further down. The queued tracks are gone, and Previous does nothing.
