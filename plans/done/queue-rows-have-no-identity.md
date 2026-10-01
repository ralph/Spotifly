# Queue rows have no identity, so every jump finds its row again by uri

Status: **Done** 2026-10-01. The history and part 1 (#105, #94), seen in the running app on
2026-09-30; part 2, the rows' uids, built and seen against the web player on 2026-10-01. A
queued copy of an album's track is still named by uri, which needs a phone to settle:
`plans/open/queued-copy-of-an-album-track.md`. See Progress.
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
   the resolver's uid or the context index for context tracks (the resolver's uids reach `play`
   since the handover fix, but `PlaybackQueue` does not keep them), and history kept as entries
   rather than uris. Report the uids in the cluster
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
  - Seen in the running app, 2026-09-30, with the web player as the other device. Four quick
    Nexts, a double-click several rows ahead, Previous twice, and tracks running out by
    themselves: the queue and the bar agreed each time, within 0.4 s. Next in the last second
    and a half of a track played the track after it and never the one after that, also with
    repeat-one on, where the old track did not come back. The mirrored queue followed the web
    player's with the right current row. The history as positions (#105) was not tried live: it
    needs a context holding a track twice.
- **Part 2, uids: not done, and what is left of it** (2026-09-29). With the queue published
  with its track, the view's list is split where the player's is, so a row's index names the
  exact row and `nearestIndex` finds it at that index. What uids would still fix:
  - **`skip_next` from the web player** names a track by uri, and a duplicate ahead resolves to
    the first copy. librespot's `handle_next` does the same (`skip_next.track.map(|t| t.uri)`);
    go-librespot matches a uid first (`tracks.ContextTrackComparator`).
    - **Measured** 2026-10-01: a double-click on a row three ahead in the web player's queue
      panel, while Spotifly played an album, sent
      `{"endpoint":"skip_next","track":{"uri":"spotify:track:6n7G4IAZjZMYFY3wygXG2H","provider":"context"}}`:
      no uid, since Spotifly reports its rows without one, but a `provider`. A uid could only
      come back once Spotifly reports its rows with uids.
    - **The `provider` does not tell the copies apart.** Measured the same day with a track both
      queued and further on in the album: a double-click on the album's own copy in the web
      player's queue panel sent `"provider":"queue"`, twice, with two tracks. The web player
      looks the row up by uri and names the first match, the queued one. A branch that picked the
      row by provider was built, measured, and dropped.
  - **Rows the store drops.** `QueueService` keeps only track rows, so a context with episodes
    shifts the view's indices past the first one. The uri still finds the row unless the track
    repeats close by.
  - What it would take: `q<n>` uids for queued tracks as librespot's `add_to_queue` makes them;
    the resolver's uid for context rows, which reaches `play` as `ResolvedContext.uids` but is
    not kept in `PlaybackQueue`. **Measured**
    2026-09-30 from the app's own log of context-resolve answers: a playlist's rows carry a
    `uid` each (Liked Songs `"uid":"95942ae3715ec9d21e76"`, a user's playlist
    `"uid":"53ff0e713d18ef43"`), an album's carry none. librespot's `context.rs` generates a
    UUID when one is missing. The same uids now place a handed-over track, relinked or
    repeated; see `plans/done/handover-of-a-relinked-track-starts-at-the-top.md`. Once
    `PlaybackQueue` keeps them, the parallel `tracks` and `uids` arrays of `start` and
    `ResolvedContext` should become one list of rows, so an inserted track keeps them aligned.
    Inventing uids for the rows other devices see risks confusing a
    receiving device's own matching (`context.rs` copies a transferred uid onto its context
    track), so measure first.
- **Part 2, built** (2026-10-01). Every row the queue lists can carry a uid, and the queue,
  the cluster and a jump all use it:
  - **Queued tracks are named `q0`, `q1` and on** (`PlaybackQueue.queued`, rows as `QueueItem`),
    as librespot's `add_to_queue` names them, and keep the name while they play. The count goes
    on across the queue's life, so no two rows of one queue share one. A handover's or a
    `set_queue`'s rows are named afresh, as librespot's `set_next_tracks` names them.
  - **Context rows carry the resolver's uids**, kept beside `contextTracks` as `contextUids`.
    A playlist's rows have them; an album's do not, unless the handover fetched pathfinder's
    (#116), and none is invented for them, which the plan warned could confuse a receiving
    device's own matching. `start` returns the uids aligned with the tracks, with none for a
    track put in, so a relinked or missing track no longer shifts the uids after it.
  - **Reported**: the current track, the next tracks and the previous tracks go out with their
    uids (`SpircPlayerState.trackUid`, the rows' `uid`), as librespot reports them.
  - **A `skip_next` naming a uid** goes to that row, where a row ahead has that uid and that
    track, and otherwise falls back to the uri, as before. (go-librespot takes the first row
    whose uid *or* uri matches, `ContextTrackComparator`.) For a playlist, that is the case the
    provider could not settle: a track queued and further on in the context. For an album,
    whose rows have no uid, it settles nothing until the measurement below says what the web
    player sends for a row without one.
  - **The queue view's rows carry them too** (`QueueItem.uid`), next and previous, so a
    double-click on this Mac's queue names its row by uid, and `stepBack(toRecent:uri:uid:)`
    finds a previous row as `skip(toUpcoming:uri:uid:)` finds a next one. A context with
    episodes, whose rows the store drops, no longer shifts which row that is, wherever the rows
    have uids. The mirrored previous rows keep the cluster's uids too.
  - **The rewind at the end of a context keeps its rows** (`PlaybackQueue.rewind(to:)`), so its
    uids are not lost or passed back in by the client.
  - **Not done:**
    - The parallel `tracks` and `uids` of `start` and `ResolvedContext` did not become one list
      of rows; `start` keeps them aligned instead. A list of rows would touch every reader of
      `contextTracks` and the resolver for no change in behaviour.
    - The three `nearestIndex` re-finds the Solution expected to go stay, as the fallback for
      a row without a uid: `start`, `skip(toUpcoming:)` and `stepBack(toRecent:)`.
    - An album's rows go by uri, unless their pathfinder uids were fetched (#116), and those
      are keyed by uri, so an album's repeated track would share one. Treating a missing uid as
      a value, nil matching nil, would settle the queued-and-in-the-album case without
      inventing or fetching anything, if the web player turns out to send a uid only for rows
      that have one.
  - **Measured** 2026-10-01, this build beside the web player, Liked Songs playing on the Mac
    from row 199 and row 202, "Drag My Body", queued as well:
    - A double-click on the playlist's copy in the web player's queue panel sent
      `next(trackUri: …0bEwPQwwgFyCvsqLkVOWhh, uid: "e5df41f3708dea21f113")`, the row's uid
      from the resolver. The Mac played row 202, three tracks went into the history, and the
      queued copy stayed queued. Before, the same click played the queued copy.
    - A double-click on the queued copy sent `uid: "q0"`, and the Mac played it as queued.
    - Handed to the web player while the queued copy played, the web player went on with row
      203 after it; handed back, the Mac took the queued copy (under its other, relinked id,
      `3yZJDgC3…`, which the web player's queue held) over as queued, with the context
      resuming at 203 by the transfer's uid. Handed to the web player mid-playlist after a Next,
      it went on with the right row too.
    - On this Mac's own queue, a double-click on a next row and on a played row went to those
      rows.
    - **An album's row has no uid, and the web player sends none for it**: a double-click on a
      row of "Fashion Nugget" in its queue panel sent `uid: nil`. So a track queued and
      further on in an album is still taken from the queue when its album copy is clicked; see
      the open plan named in Status.
