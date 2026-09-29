# The queue lists its history newest first

Status: **Open.** Recorded, not planned. Read from the code, not observed in the app.
Components: `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`recent`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`publishQueue`, `spircState`, the
mirrored queue), `Spotifly/Views/QueueListView.swift`, `Spotifly/Store/AppStore.swift`
(`Queue.reconciled`)
Found: 2026-09-29, while checking a review finding on #77 for the plan in #79.

## Summary

The queue shows the tracks already played above the current one, with the most recent at the
top. Read from top to bottom, the history runs backwards: the track that played just before
the current one is the furthest from it. Everything else that reads the queue expects play
order.

## Problem

### Where the order turns

- `PlaybackQueue.recent(limit:)` returns `history.suffix(limit).reversed()`, the last ten
  tracks played, newest first.
- `LibrespotClient.publishQueue` hands that to the UI as `previousTracks` unchanged.
- The mirrored queue, while another device plays, reverses the cluster's `prev_tracks` the
  same way (`remote.prevTracks.reversed()`), so both paths give the UI newest first.
- Connect gets play order: `spircState` reverses it back
  (`Array(playbackQueue.recent().reversed())`). So the app's own `prev_tracks` are oldest
  first, and the UI's copy is the reverse of that.

`recent()` and both reversals came with the Swift stack (#65, 2026-09-27). Nothing records
that newest first was intended for the UI.

### Who expects play order

- `QueueListView.allQueueItems` is `previousTracks + current + nextTracks`, shown as one
  list, and dims rows with `index < currentIndex` as played.
- `Queue.reconciled(currentTrackId:)` treats `previousTracks + current + nextTracks` as one
  list in play order and looks for the playing track nearest the split. The tests in
  `QueueReconciliationTests` build `previousTracks` as `ids[..<currentIndex]`. With the
  history reversed, a track that is in the history twice could be matched to the wrong
  copy. That is read from the code, not observed.
- `plans/done/queue-current-pointer-lags-requested-index.md` was written when
  `previousTracks` was in play order, under librespot.

A double-click on a history row plays the wrong track for the same reason, but that is the
row-index problem in `plans/open/clicked-row-plays-another-track.md` (#79). Once that is
fixed, the order no longer decides what plays, and this is only about what the list shows.

## Solution

Not planned yet. The likely fix: `recent()` returns play order, `spircState` stops reversing
it, and the mirrored queue takes `prev_tracks` as it comes. Before that, check that nothing
else depends on newest first. The persisted queue snapshot in `AppStore` stores and restores
`previousTracks` as it is.

## Verification

Not defined yet. What would show the problem: start an album at its first track and let
three tracks play. The queue should read 1, 2, 3 above track 4. The code says it reads 3, 2, 1.
