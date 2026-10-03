# A double-click in the queue starts its context over

Status: **Done** 2026-09-29 (#86). Built, unit-tested, and the six live checks passed on
`ff9c6f7` the same day; see Verification. Starting a *context* by uid is not done; see Solution.
Components: `Spotifly/Views/QueueListView.swift`, `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift`
(`skip(toUpcoming:uri:)`, `stepBack(toRecent:uri:)`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`skip(toNext:uri:)`,
`skip(toPrevious:uri:)`, the mirrored queue, the remote `.next` command),
`Spotifly/SwiftLibrespot/Dealer/DealerConnection.swift` (`skip_next`), `Spotifly/ViewModels/PlaybackViewModel.swift`
(`play(queueRow:)`), `Spotifly/PartnerAPI/ConnectState.swift` (`skipNext(to:uid:)`),
`Spotifly/SpotifyPlayer.swift` (`QueueItem.uid`), `Spotifly/Store/AppStore.swift`
(`QueueEntry.uid`), `Spotifly/Store/Services/QueueService.swift`
Found: 2026-09-29, Step 3 of `plans/done/clicked-row-plays-another-track.md`

## Summary

Since #79, a double-click on a queue row played the track clicked, but by playing the queue's
context again from that track. The queue it had was gone: the history, the tracks queued by
hand, the shuffle order. Now the queue jumps to the row and keeps everything else, the way
Spotify's own queue does. On another device, the command is the web player's own: `skip_next`
naming the row's track and uid.

## Problem

`QueueListView` played `store.queue.contextUri` with the row's track, and
`LibrespotClient.play` resolved the context again and built a new `PlaybackQueue` from it:

- **The history went.** `setContext` clears it, so Previous had nowhere to go.
- **Tracks queued by hand went.** They are not in the context. Double-clicking one played it,
  then the context from its first track. The others were dropped.
- **The shuffle order was drawn again.** `setContext` reshuffles.
- **Copies were a guess.** A queue row's index counts queue rows, not context tracks.

A remote device was the same: the view sent a `play` command, and the device resolved the
context again.

## Research

- **The web player** plays a queue row with `skipToNext({uri, uid})`, with
  `featureIdentifier: "queue"`, read from its bundle on 2026-09-29. On the wire that is a
  `skip_next` with a `track`.
- **librespot** (`spirc.rs`, `handle_next`) steps forward with `next_track` until the current
  track is the uri named. Context tracks it passes go into `prev_tracks`. Queued tracks ahead of
  a context track are consumed on the way.
- **go-librespot** (`skipNext`) seeks within the context to the track, by uid, else uri, else
  gid. The queue is a separate list and stays.
- **Connect has no jump backwards** to a named track: `skip_prev` takes none.

## Solution

1. **A local jump forward**, `PlaybackQueue.skip(toUpcoming:uri:)`, moves to a row of
   `upcoming()` the way Next would get there. Context tracks passed over go into the history,
   as both references put them in the previous tracks. A queued target drops the queued tracks
   before it. A context target leaves the queued tracks queued, to play after it, as
   go-librespot does. That is the plan's complaint, and what one queued them for.
2. **A local jump back**, `PlaybackQueue.stepBack(toRecent:uri:)`, steps back to a row of
   `recent()`, as Previous pressed that many times would. `recent` and the jump share
   `recentPositions`, so the row found is the row shown, whichever order the list has.
3. **The track decides.** Both find the row's track nearest the row's index, as `start` does
   since #79. The view's list can be split a row away from the client's while the store
   reconciles it (`Queue.reconciled`), so an index alone could name the neighbour. A track no
   longer listed plays nothing, and throws, so the view model takes back the display's move to
   0:00 (found in review: returning quietly left the bar at 0:00 over the old track).
4. **Remotely**, a next row sends `skip_next` with `track: {uri, uid}`
   (`ConnectCommand.skipNext(to:uid:)`). The uid comes from the cluster's `ProvidedTrack.uid`,
   now kept on the mirrored `QueueItem` and on `QueueEntry`. A previous row still plays the
   context from its track, as every row did before, since Connect has nothing better.
5. **The other way round**, a `skip_next` another device sends here with a `track` jumps to
   that track, the first copy ahead, as librespot's `handle_next` does. It was read as a plain
   Next, so a row clicked in the web player's view of this Mac's queue skipped one track.
6. **The current row** restarts its track, and resumes it if paused.
7. `PlaybackViewModel.play(queueRow:)` takes all of it, through the same local-or-remote route
   as Next. Next, Previous and the jumps share one `skip` helper there, which moves the display
   to the track's start.

The (index, uri) addressing is a stopgap: no row in the queue has an identity. That, and the
queue published after the track, which is what lets the view's split lag, are
`plans/done/queue-rows-have-no-identity.md`.

Not done: **starting a context by uid.** The resolver's tracks carry a `uid`, the same one
`fetchPlaylistContents` gives a playlist item (`"uid":"87ced089511bc3c325f3"` for the first
Liked Songs track on 2026-09-29), and `SPClient.parseContextReport` keeps only the uri. Starting
by uid would pick the right copy of a duplicated playlist track with no guessing. It is the
playlist view's problem, not the queue's, and the index already picks the copy there.

### Merging with #81

#81 lists the history in play order by dropping `.reversed()` from `recent`. Here, `recent` reads
`recentPositions`, so after both land the `.reversed()` belongs in `recentPositions`, if
anywhere: drop it there. The jump back finds the row through the same function, and its test
looks the row up through `recent()`, so it holds in either order.

Done in #81's merge of `main`, 2026-09-29: `recentPositions` lists `history`'s last indices in
play order, and `recent` keeps #81's documentation.

## Verification

- [x] Unit tests, `QueueJumpTests`, eight cases: a context row ahead (history gains the tracks
      passed over), queued tracks kept past a context row, a queued row, shuffle order kept,
      copies picked by the index, the first copy without one, a row no longer listed, and a
      step back to a history row.
- [x] `skip_next` carries the track and uid, and the uri alone without one; one received is
      read with its track, or without. A mirrored row keeps its uid into the store.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, 2026-09-29.
- [x] Live, local: start an album at track 1 and queue two tracks by hand. Double-click the
      album's track 5 in the queue. It plays; both queued tracks are still next; the history
      shows tracks 1 to 4. Press Previous: track 4.
- [x] Live, local: double-click the second queued track. It plays; the first is gone; the album
      continues after it.
- [x] Live, local, shuffle: note the next five tracks, double-click the third. The two after it
      are the same as before.
- [x] Live, local: double-click a history row. It plays; the rows after it are next again.
- [x] Live, remote: with the web player playing an album, double-click a later row in this
      app's queue. The web player plays that row, without starting the album over.
- [x] Live, the other way: with this Mac playing an album, click a later row in the web
      player's queue panel. The Mac plays that row.
      All six **passed** on `ff9c6f7` (with #84 and `main` merged in), 2026-09-29.
