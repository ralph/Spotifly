# The queue lists its history newest first

Status: **Done** 2026-09-29 (#81). Built, unit-tested, and the live checks passed on `98808b6`
(with `main` and #86 merged in) the same day; see Verification.
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
that newest first was intended for the UI, and the port's reference says otherwise:

- **librespot** keeps `prev_tracks` in play order. `connect/src/state/tracks.rs` pushes each
  track that ends onto the end, drops from the front once the list is full, and pops from the
  end to go back. `spirc.rs` handed that list to the app's queue unchanged, so under librespot
  the queue listed its history in play order.
- **go-librespot** builds `PrevTracks` walking backwards and then reverses it "to fix" the
  order (`tracks/tracks.go`), so it sends play order too.

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
row-index problem in `plans/done/clicked-row-plays-another-track.md` (#79). Once that is
fixed, the order no longer decides what plays, and this is only about what the list shows.

## Solution

- [x] `PlaybackQueue.recent()` returns the last ten tracks in play order, the most recent last.
- [x] `LibrespotClient.spircState` passes it to Connect as it is, instead of reversing it back.
      What Connect receives is unchanged.
- [x] The mirrored queue takes the cluster's `prev_tracks` as they come, instead of reversing
      them.
- [x] Checked that nothing else depends on newest first. `canGoBackward`, the queue position
      in the bar and `AppStore.queueLength` only count the tracks. `Queue.reconciled` and
      `QueueListView` want play order. This plan guessed that `AppStore` persists the queue.
      It does not: the only snapshot is the Debug menu's JSON dump to the clipboard.

One behaviour changes with it: a double-click on a history row now plays a different wrong
track, as long as #79's problem stands. With the history in play order, a history row's index
matches its context index when the context started at its first track and nothing was
queued. Before, only the middle row did.

## Verification

- [x] A unit test: after three tracks of an album, `recent()` is tracks 1, 2 and 3. After
      thirteen, it is the last ten, still in play order.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare with the exit
      code checked. 2026-09-29: build succeeded, 379 tests passed, lint exit 0.
- [x] Live, local: start an album at its first track and let three tracks play; skipping
      with Next is enough. The queue reads 1, 2, 3 above track 4. Before the fix it read
      3, 2, 1. **Passed** on `98808b6`, 2026-09-29.
- [x] Live, mirrored: play an album on a phone and skip three tracks there, with the Mac
      showing it. The Mac's queue reads 1, 2, 3 above track 4. **Passed**, same run.
- [x] Live, Connect: with the Mac playing after those skips, hand playback to the phone and
      press Previous there. It goes to track 3, as before. **Passed**, same run: Previous twice
      went to track 3, then track 2.
- [x] Live, with #86: after those skips, double-click track 2 in the history. It plays, and
      track 3 is next again. **Passed**, same run.
