# Queue rows have no identity, so every jump finds its row again by uri

Status: **In progress.** Read from the code in review; nothing observed. The history and part 1
are done; see Progress.
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

## Progress

- **The history as context positions** (2026-09-29, stacked on #92). `PlaybackQueue` keeps
  `historyPositions: [Int]`, where each context track that played sits in the context, and
  `history` maps them to uris for its readers. `backward()` returns to that position instead of
  `contextTracks.firstIndex(of:)`, and `stepBack(toRecent:uri:)` and `recent()` read through
  them. `setContext` is the only writer of `contextTracks` and clears the positions with it, so
  none can point into another context. A unit test: in `a b a c`, playing from the second `a`
  and pressing Previous comes back to position 2, and the context goes on with `c`; before, it
  went back to position 0, and on with `b`. That settles the Duplicates bullet.
- **Part 1: the queue is published with the track** (2026-09-29, stacked on the above).
  `startTrack` publishes the playback state and the queue in one snapshot, before the wait for
  metadata, key and CDN, through a `queue:` parameter on `publishPlaybackState`. `publishQueue`
  still runs after the load, in the same `defer`s, for one reason found on the way: it also
  announces the track to fetch ahead, and announcing it before the load cancels a fetched-ahead
  copy of the very track being loaded (`AudioPipeline.setNextTrack` drops an `upcoming` that is
  not the new next). Its second publish of the same queue changes nothing, since `PlayerModel`
  writes only what changed.
  - With queue and track always agreeing, `Queue.reconciled`, `AppStore.reconcileQueueCurrentTrack`
    and both callers are gone, with `QueueReconciliationTests`. The one gap left is the hop
    between `QueueService`'s and `PlaybackViewModel`'s observations of the same snapshot, which
    lasts until the next main-actor turn: the store's lists and the bar's track come from one
    snapshot and meet on the next turn.
  - Every other publisher already agreed: the mirror publishes queue and playback together; a
    queue change without a track change (Add to Queue, `set_queue`, shuffle) publishes the queue
    alone; and a rewind or a new context goes through `startTrack` too.
  - The review of it found three places where a track could still be published against a queue
    that had moved on, which the re-split used to paper over:
    - `handleEndOfTrack` acted on the ended track's uri in a task of its own. A Next landing in
      between had moved the queue already, so the task advanced again, passing over the track
      Next had started, or under repeat-one played the old track again under the new queue. It
      now returns when the queue's current track is no longer the one that ended.
    - `handlePipelineState` and `publishPlaybackStateRefresh` read the track, then await the
      position. A skip in that wait published its own track, which the stale state then
      overwrote until the new track's `.playing` came. Both drop a state whose track is no
      longer current.
