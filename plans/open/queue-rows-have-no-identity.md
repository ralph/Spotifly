# Queue rows have no identity, so every jump finds its row again by uri

Status: **Open.** Recorded, not planned. Read from the code in review; nothing observed.
Components: `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`loadAndPlay`, `publishQueue`),
`Spotifly/Store/AppStore.swift` (`Queue.reconciled`), `Spotifly/Store/Services/QueueService.swift`,
`Spotifly/SwiftLibrespot/Connect/SpircController.swift` (the reported tracks),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`parseContextReport`)
Found: 2026-09-29, in the altitude review of `plans/done/queue-double-click-restarts-the-context.md`

## Summary

The context, the tracks queued by hand and the history are all lists of uris. Nothing names a
row. So each operation that means one row finds it again as "this uri, the copy nearest this
index": `PlaybackQueue.start`, `skip(toUpcoming:uri:)`, `stepBack(toRecent:uri:)` and
`Queue.reconciled`. It works, but duplicates are guessed, and the list on screen has to be
trusted to be split where the player's is.

## Problem

- **The queue is published after the track.** `loadAndPlay` publishes the new track before it
  waits for metadata, key and CDN. `publishQueue` runs in a `defer` after that wait: in
  `previous()`, `advanceUserInitiated()`, `handleEndOfTrack` and the new jumps. For the whole
  load, the store holds the old lists and a new current track, and `Queue.reconciled` re-splits
  them around it. That window is why the view's index can be a row off.
  - `reconciled` came from Rust librespot's early `SetQueue`
    (`plans/done/queue-current-pointer-lags-requested-index.md`). That cause is gone.
  - While it re-splits, it joins `previousTracks` to the rest as if they were in play order,
    and before #81 they are not.
  - The mirror of another device already publishes queue and playback together.
- **Rows the store drops.** `QueueService` keeps only rows whose uri is a track. An episode in the
  queue shifts every index after it, whatever the split.
- **Duplicates.** `backward()` returns to `contextTracks.firstIndex(of:)`, the *first* copy of a
  track the context holds twice, whichever copy the history meant.
- **No uids on the wire.** `SpircController` reports next and previous tracks without uids, so
  the web player's `skip_next` names this device's rows by uri alone.

## Solution

Not planned yet. Two parts, either first:

1. **Publish the queue with the track**, in the same `publish {}` inside `loadAndPlay`, before
   the wait. Then see whether `Queue.reconciled` and both `reconcileQueueCurrentTrack` callers
   can go.
2. **Give rows an identity**, as librespot does: `q<n>` uids for queued tracks (`tracks.rs`),
   the resolver's uid or the context index for context tracks (`parseContextReport` drops the
   uid today), and history kept as entries rather than uris. Report the uids in the cluster
   state. The queue view's rows would then name a uid, the three `nearestIndex` re-finds would
   go, and a `skip_next` from the web player would name the exact copy.

Part 2 changes the `PlaybackQueue` model. Its history needs no "was this entry queued?":
since `plans/done/history-repeats-the-track-before-a-queued-one.md` it holds context tracks
only, as librespot's does. So keeping it as entries can be `history: [Int]`, context indices,
which `setContext` already clears whenever the context changes. That alone fixes the
Duplicates bullet, and can land before the uids.

## Verification

Not defined yet.
