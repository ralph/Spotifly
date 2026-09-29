# Double-clicking a row can play another track

Status: **Done** 2026-09-29 (#79). Built and unit-tested. Steps 1 and 2 are done; Step 3 is
decided and its better half is in `plans/open/queue-double-click-restarts-the-context.md`.
Not yet seen in the running app; see Verification.
Components: `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`start(in:index:uri:)`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`play`, the remote `.play` command), `Spotifly/ViewModels/PlaybackViewModel.swift` (`play(uriOrUrl:trackIndex:)`),
`Spotifly/SpotifyPlayer.swift` (`play`), `Spotifly/PartnerAPI/ConnectState.swift`
(`Context.init`, `SkipTo`), `Spotifly/Views/QueueListView.swift`,
`Spotifly/Views/FavoritesListView.swift`, `Spotifly/Views/PlaylistDetailView.swift`,
`Spotifly/Views/AlbumDetailView.swift`
Found: 2026-09-29, in a review of #77, which fixed one instance of it for Liked Songs.

## Summary

A double-click starts playback by the row's **index** into a context the player resolves on
its own. The row plays only if the view's list and the resolved context agree position for
position, and nothing guarantees that. In the queue they disagree in the normal case. #77 made
Favorites agree by reading the list from the same playlist it plays, which fixes that list but
not the mechanism. The player already knows how to start at a named track (`startingAtUri`).
The fix is to pass the clicked track's uri with the index and let the player check one against
the other.

## Problem

### How a double-click starts playback

The four views call `PlaybackViewModel.play(uriOrUrl: contextUri, trackIndex: index)`, where
`index` is the row's position in the view's own list. Locally that reaches
`LibrespotClient.play(uriOrUrl:trackIndex:startingAtUri:…)`, which resolves the context
through spclient `context-resolve` and starts at `tracks[trackIndex]`. `startingAtUri` exists
and is used by resume, transfer and remote play, but an index `>= 0` wins outright. With
another device active, the view model sends a Connect play command instead, and
`ConnectState.Context.init(uri:trackIndex:)` puts only `track_index` into `skip_to`, although
`SkipTo` has a `track_uri` too.

### The queue: wrong in the normal case

`QueueListView.allQueueItems` is `previousTracks + current + nextTracks`, and its double-click
plays `store.queue.contextUri` at the row's index. That list is not the context:

- `previousTracks` is `PlaybackQueue.recent()`: at most 10 tracks, **most recent first**
  (`history.suffix(limit).reversed()`, passed through unreversed by `publishQueue`), and only
  since the context last started, because `setContext` clears the history.
- `nextTracks` is `PlaybackQueue.upcoming()`: the user queue first, then at most 50 context
  tracks, in shuffle order when shuffle is on.
- Rows whose track is not in the store are dropped.

So a row's index is its context index only when the context started at its first track,
nothing is queued, shuffle is off, and the row is not in the history, apart from the middle
row of an odd-length history. Start an album at track 5, and the row after the current one
is index 1: it plays track 2.

`plans/done/queue-current-pointer-lags-requested-index.md` lists "double-clicking a queue row"
as unaffected. That was true under librespot, whose queue held the context from its start. It
stopped being true with the Swift queue.

### Favorites, playlists, albums: wrong when the list and the context disagree

Each list is built separately from the context the player resolves, and each can drift from
it by one or more rows, which shifts every row below:

- **Favorites.** `setSavedTrackIds` and `appendSavedTrackIds` deduplicate relinked tracks,
  `favoriteTracks` drops ids missing from the store, and `addTrackToFavorites` inserts at the
  top before Spotify has the write. #77 removed the large case: `spotify:collection:tracks`
  resolved 121 of 609 rows to another song, because ties in `addedAt` are ordered differently.
- **Playlists.** `PathfinderPlaylistUnion.entities()` drops items with no uid or no readable
  track, and the rows drop tracks missing from the store. An owner's drag-reorder is applied
  before Spotify has it. Whether the resolver keeps episodes, local files and unavailable
  items that the list drops is not measured.
- **Albums.** The rows drop tracks missing from the store, and are otherwise in album order.
  Low risk.
- **All of them.** `SPClient.resolveContext` stops after 10 resolver pages, and an index past
  what came back is clamped to the last track.

### Remote Connect

- **Outgoing.** With another device active, `skip_to` carries only the index, so the same
  mismatch plays the wrong track on the phone.
- **Incoming.** A remote `.play` command with a context passes `trackIndex: playCommand.index`
  and `startingAtUri: playCommand.trackUri` together, and the index wins. A sender whose
  index is stale plays the wrong track here, although it named the right one.

## Solution

Start at the clicked track. The index stays as a hint, because a playlist can hold the same
track twice and only the position says which.

### Step 1: the player checks the index against the uri

- [x] Pull the start choice out of `LibrespotClient.play` into a pure function over the
      resolved tracks, the index and the uri, so it can be tested without a session.
      **Done** as `PlaybackQueue.start(in:index:uri:)`. The nearest copy comes from
      `Array.nearestIndex(to:where:)`, which `Queue.reconciled` now uses too, so the rule lives
      in one place.
- [x] Precedence when both are given: the index if `tracks[index]` is that uri. Otherwise the
      occurrence of the uri nearest the index, searching both ways and preferring the nearer.
      `Queue.reconciled(currentTrackId:)` already solves the same problem and is the model.
      Otherwise insert the uri at the front and start there, as `startingAtUri` alone does
      today. Only an index, or only a uri, behave as they do now.
      **One change:** with an index, a track the context does not name goes in *at* the index,
      not in front, so what plays after it is what followed its row. Without an index it still
      goes in front. Measured before choosing, on 2026-09-29 from the web player: the resolver
      and pathfinder named the same ids in the same order for Liked Songs (320 of 320), for the
      test playlist, and for both "Food In The Belly" albums, the original and the market
      substitute holding "The Letter". So a track missing from the context means a list older
      than the context, not two ways of naming one track, and the index says where it was.
- [x] The incoming remote `.play` gets this for free, since it already passes both.

### Step 2: pass the track from the views

- [x] Add `startingAt trackUri: String?` to `PlaybackViewModel.play(uriOrUrl:trackIndex:)` and
      `SpotifyPlayer.play`, and pass it to `LibrespotClient.play` locally. The view model also
      counts the clicked track, not the context, as the one that started, so the bar shows it at
      once.
- [x] Remotely, `ConnectState.Context.init` sets both `track_uri` and `track_index` in
      `skip_to`. Check what a phone does with both: if it prefers the index, the outgoing case
      needs the corrected index from Step 1, computed before sending.
      **A receiver prefers the uri.** librespot's `PlayingTrack::try_from` takes the uri, then
      the uid, and the index "only as last resort", and go-librespot's `loadContext` matches the
      uid or the uri before the index. The web player's own `skip_to` builder sends `track_uri`,
      `track_uid`, `track_index` and `page_index` together. So no corrected index is needed.
      What Spotify's phone app does is not observed; see Verification.
- [x] The four call sites pass the row's `track.uri`: `QueueListView`, `FavoritesListView`,
      `PlaylistDetailView`, `AlbumDetailView`. The queue view sends the track alone: a queue
      row's index counts queue rows, not the context's tracks. The `-1` that meant "no index"
      is gone; `trackIndex` is an optional from the views to `LibrespotClient.play`.

### Step 3: decide what a queue double-click means

- [x] With Steps 1 and 2 it plays the right track, by resolving the context again. That drops
      the history, and a user-queued row that is not in the context is inserted at the front.
      The exact alternative is skipping to that position in the existing `PlaybackQueue`,
      without resolving anything, which needs a skip API on the queue and an equivalent for a
      remote device. Decide which the queue view wants. Steps 1 and 2 fix the wrong song
      either way.
      **Decided:** resolving again stays for now, because it plays the right track everywhere
      and needs nothing new. Skipping within the queue is what the queue view should do in the
      end: it keeps the history and the user queue. That is
      `plans/open/queue-double-click-restarts-the-context.md`.

### Not in this plan

- **A remote play of a bare track list**, and a handover of one, still choose their start on
  their own: `plans/open/remote-track-list-play-starts-at-the-top.md`.
- **Starting by uid**, now in `plans/open/queue-double-click-restarts-the-context.md` beside
  the queue skip, which needs an exact row too. The resolver's tracks carry a `uid`: the app's
  log on 2026-09-29 shows `"uid":"87ced089511bc3c325f3"` for the first Liked Songs track, the same uid
  `fetchPlaylistContents` gives that item. `parseContextReport` keeps only the uri. Starting
  by uid would pick the right copy of a duplicated playlist track with no guessing, but only
  where the view has a uid, so it refines Step 1 rather than replacing it.
- **History shown newest first.** Because `previousTracks` arrives most recent first, the
  queue lists the history upside down above the current track. Read from the code, not
  observed. Once Step 1 starts at the uri, the row order no longer decides what plays, so
  this is a display question of its own. Fixed in #81.

## Verification

- [x] Unit tests for the start choice: the index matches; the index is stale and the uri is
      ahead of it, and behind it; two occurrences, nearer one each side; the uri is absent;
      the index is out of range; only an index; only a uri. `ContextStartTests`, ten cases,
      with a tie and "neither" besides. Two more pin `skip_to` carrying both fields.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare with the exit
      code checked. 2026-09-29: build succeeded, all tests passed, lint exit 0.
- [ ] Live, queue: start an album at track 5 and let two tracks play. Double-click the row
      after the current one, then a history row. Each plays the track clicked. Repeat with a
      queued track and with shuffle on.
- [ ] Live, Favorites: heart a track that is not saved, and before the list refreshes,
      double-click a row below the top. It plays the row clicked.
- [ ] Live, remote: with a phone playing, double-click a track in an album on the Mac. The
      phone plays that track. Then, from the phone, start a playlist track on the Mac. The Mac
      plays that one.
