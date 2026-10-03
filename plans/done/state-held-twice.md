# Some state is held twice, and the playback view model is passed by hand

Status: **Done** 2026-10-02, in four PRs: #159 (phase 1), #160 (phase 2), #161 (phase 3) and #162
(phase 4), each checked live. The plan is #158. Follow-ups are their own open plans, linked under
Solution
Components: `Spotifly/Store/AppStore.swift`, `Spotifly/Store/Entities.swift`,
`Spotifly/Store/PlayerModel.swift`, `Spotifly/Store/Services/QueueService.swift`,
`Spotifly/Store/Services/SearchService.swift`, `Spotifly/Store/Services/DeviceService.swift`,
`Spotifly/Store/Services/PlaylistService.swift`, `Spotifly/Store/Services/TrackService.swift`,
`Spotifly/Store/Services/AlbumService.swift`, `Spotifly/Store/Services/ArtistService.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/Views/LoggedInView.swift`,
`Spotifly/Views/LoggedInLifecycleModifier.swift`, `Spotifly/Views/QueueListView.swift`,
`Spotifly/Views/NowPlayingBarView.swift`, `Spotifly/Views/SearchResultsView.swift`,
`Spotifly/SpotiflyApp.swift`, a new `Spotifly/Store/Services/ProfileService.swift`, and every
view that takes a `playbackViewModel` argument
Found: 2026-10-02, reviewing the store against current practice

## Summary

The store is sound, and this is not a rewrite. Its entities sit in tables keyed by id. Ordered
collections and the start page's shelves hold ids. Writes go through named methods behind
`private(set)`, loads are single-flight, and everything is injected through the environment. No
view keeps a `@State` copy of an entity. That is still how a SwiftUI app with `@Observable`
should hold server data. It needs no split into several stores, no framework, and no
persistence layer.

Four things fall short of one source of truth that each view reads directly:

1. **`AppStore.queue` is a copy of `PlayerModel.queue`.** An observation refreshes it, and two
   other paths copy it again. A freshness counter is left over from when one of those paths was
   an HTTP request.
2. **Search results are cached as whole entities**, beside the tables they were also written
   into, and the results page draws its cards from those copies.
3. **`PlaybackViewModel` is passed by hand** through some 20 views. It is an `@Observable`
   singleton, and every other shared object comes from the environment.
4. **Some writes happen outside the services**, in a view or in a second copy of a service
   method: the library refresh, the profile load, and ⌘L's favorite toggle.

Each is one PR. Phase 1 is mechanical, so it goes first, before the other phases build on the
files it touches.

## Problem

### The queue is held twice

`LibrespotClient` publishes the queue, and `PlayerModel.queue` holds it: a `QueueState` of rows
as uris, plus the context and its name. `QueueService` observes it and writes a translated copy
into `AppStore.queue`. That copy is a `Queue` of `QueueEntry`s (track id, provider, uid), with
any row whose uri is not a track left out. Views read both:

- `QueueListView` takes its rows from `store.queue` and its header's context from
  `player.queue`.
- `NowPlayingBarView` counts "3/20" from `store.queue`.
- `PlaybackViewModel.hasPrevious` reads `store.queue`.

The copy has already drifted once. The store used to keep the context too, and it kept the last
non-empty one, so a bare list of tracks played under the previous album's name. That copy was
removed, and the header now reads the player (see the comment on
`QueueListView.contextInfo`). The rows are the same arrangement, one step removed. A task writes
them after the player's value changes, so nothing guarantees that the header and the rows
describe the same queue in any given frame.

There are two writers, and they guard differently:

- **The observation** applies any non-nil queue, an empty one included.
- **`fetchInitialPlaybackState()`**, called at launch, on reconnect and after a remote start,
  refuses a queue with nothing current and nothing next (`queueUpdate(from:)`, the
  wake-from-sleep fix in `plans/done/wake-from-sleep-loses-queue-and-resume.md`).

Both read the same `player.queue`, so the stricter guard only protects against itself.

`fetchInitialPlaybackState()` used to be two Web API requests, `/me/player` and
`/me/player/queue`. Its doc says it now reads the last cluster update and that "the freshness
barrier is gone", but the code around it still assumes a request:

- **The freshness counter is still in use.** `AppStore.liveStateRevision` /
  `noteLiveStateReceived()` is bumped by `QueueService` and by
  `PlaybackViewModel.handlePlaybackStateUpdate`. `PlaybackViewModel.startRemotely` reads it: it
  waits 600 ms after a remote start and then, if nothing has arrived, copies `player.queue`
  again. The observation has already copied that same value.
- **The reconnect waits on a transfer for nothing.** `DeviceService.waitForTransferSettling()`
  delays the reconnect's re-copy by up to 5 s after a transfer, because the re-copy "reads the
  last cluster update and would otherwise read the one from before the transfer". But reading
  the player's value later only gives what the observation already applied.

One thing the re-copies still do is ask for missing track metadata. A fetch that failed earlier
is not retried by anything else, because `player.queue` can come back unchanged after a
reconnect or a remote start, and `PlayerModel.apply` writes only values that changed. That job
has to survive.

### Search results are cached as entities

`SearchService.search` writes a `SearchResults` value into `searchResultsByQuery`, holding
`[Album]`, `[Artist]`, `[Playlist]` and `[Track]`, then upserts the same entities into the
tables. `SearchResultsView` and its cards draw from the copies. "Show all"
(`SearchAllTracksView`) takes ids and draws from the table. So the two pages can disagree about
the same thing:

- **A track playback finds withheld after the search** is greyed in the table (`setWithheld`),
  and so on "Show all". Its search card stays at full opacity, because `TrackCard` reads
  `isPlayable` from the copy.
- **An owned playlist renamed, or given a new cover, through Edit Details** keeps its old name
  and image on the search card.
- **Merges miss the copies.** `upsertPlaylist` merges in the owner, the description and the
  items, and `upsertAlbum` never downgrades an album; the copies get neither.
- **A deleted playlist** is gone from the table, but its card stays in the results.

The start page already does this right: `HomeSection` holds `HomeItem` ids, and its doc says
why.

### The playback view model is passed by hand

`LoggedInView` reads `PlaybackViewModel.shared` and hands it to the two routers. The routers
hand it to every section and detail view, and those hand it to `LibraryListView`,
`LibraryRow`, `TrackRow`, `TrackCard`, `TrackContextMenu` and `NewPlaylistPrompt`.

Five views take it only to pass it on: `LoggedInContentRouterView`, `LoggedInDetailRouterView`,
`AlbumsListView`, `ArtistsListView` and `PlaylistsListView`. Everything else that is shared
comes from `@Environment`: the store, the services, the coordinator, `PlayerModel` and
`WindowState`.

Smaller cases of the same thing:

- **`NowPlayingBarView` takes `windowState` as an argument**, though its parent read it from
  the environment.
- **`onLogout` passes through `LoggedInContentRouterView`** only to reach `UserProfileView`.
  It is one closure, one level deep.
- **`LoggedInView.searchService` is a computed property.** Every evaluation of the body builds
  and injects a new instance, so the views that read it see a new environment value each
  time. It holds no state, so nothing is lost; it is only churn.

`currentSection` and `selectionId` on `TrackRow` and `TrackContextMenu` look like drilling but
are not. They say which list the row sits in: the queue panel's rows are in `.queue`, whatever
the sidebar shows. They also travel only one level.

### Writes outside the services

- **The library refresh.** `LoggedInView.refreshAction(for:)` resets the section's pagination
  and empties its id list. It then calls the service with `forceRefresh: true`, which resets
  the pagination again. What a refresh means is decided in the view, and half of it is
  repeated in the service.
- **The profile.** `LoggedInLifecycleModifier.loadProfile()` calls `PartnerAPI().profile()`
  and writes the store. `PlaylistService.requireProfile()` fetches the same thing through
  `InFlightRequests`. That is two fetch paths for one entity, and only one is single-flight.
  `requireProfile()` runs only for a playlist write, so the two overlap when one starts while the
  launch's request is still out.
- **⌘L's favorite toggle.** `PlaybackViewModel.toggleCurrentTrackFavorite()` is a copy of
  `TrackService.toggleFavorite(trackId:)`. Its own doc says so, and says it is worth
  collapsing.

## Solution

### 1. The playback view model from the environment

- `SpotiflyApp.mainWindow` injects `PlaybackViewModel.shared` beside `PlayerModel.shared`.
  Injecting it in `LoggedInView` would not be enough: `LoggedInLifecycleModifier` is applied
  outside `LoggedInView`'s own `.environment` calls and would not see it. Every view that takes
  a `playbackViewModel` argument reads `@Environment(PlaybackViewModel.self)` instead, and the
  pass-through parameters go. `NewPlaylistPrompt` and the lifecycle modifier are
  `ViewModifier`s and can read it the same way.
- `SpotiflyCommands` keeps `PlaybackViewModel.shared`. Commands are not under `LoggedInView`,
  and the singleton is what keeps them working with the window closed.
- `NowPlayingBarView` reads `WindowState` from the environment.
- `SearchService` becomes `@State`, like the other services.

No behavior change.

### 2. Search results as ids

- `SearchResults` holds `albumIds`, `artistIds`, `playlistIds` and `trackIds`, each
  `uniqued()`. `SearchService` upserts the entities first and records the ids after them.
  Relinking can give two track results one market id, and the results page's `ForEach` is
  keyed by id. That is a hazard today too; recording ids is the place to close it.
- `SearchResultsView` resolves the ids through the tables in four one-line computed
  properties, as `SearchAllTracksView` and the start page's shelves already do.
- `NavigationCoordinatorTests` and `debugDumpJSON` change with the type. A new test covers
  duplicate ids.
- Eviction does not change: `searchResultQueries` and `searchCacheEvictionRevision` now bound
  the id lists. The entities stay in the tables like everything else the app has seen, since
  the tables were never evicted.

Behavior change: the results page shows each entity as the table holds it now, and drops one
the table no longer holds (a deleted playlist).

### 3. The queue read from the player

- **One translation, in the app.** `Queue` and `QueueEntry` move out of `AppStore.swift`, and
  `Queue(_ state: QueueState?)` builds them with today's rule (`QueueService.queueEntry(from:)`):
  a row whose uri names a track, with its provider and uid. `PlayerModel` holds it as
  `queueEntries`, written in `apply(_:)` in the same call as `queue`, so the two cannot
  disagree. Worked out on each read, it cost about 1 ms per redraw of the queue panel, which
  read it once per row.
- **Readers.** `QueueListView`, `NowPlayingBarView` and `PlaybackViewModel.hasPrevious` read
  `player.queueEntries`. `currentIndex` and `queueLength` move onto `Queue`. The three entity
  lists (`currentTrackEntity` and its siblings) need the store, which `PlayerModel` does not
  have. Only `QueueService`'s log line and one count in `QueueListView` read them, so they
  become a lookup at those two places.
- **What goes.** `AppStore.queue`, `setQueue`, `liveStateRevision`, `noteLiveStateReceived`
  and the queue part of `debugDumpJSON`. `queueUpdate(from:)` goes with the copy it guarded.
- **`QueueService` keeps one job**: making sure the store has metadata for every track the
  queue names. `hydrate()` asks `ensureTracksLoaded` for it on every change of the queue,
  without the old 100 ms debounce, since `TrackService` already joins overlapping loads. The
  retry that has to survive is `retryingWhenNetworkReturns { queueService.hydrate() }`, beside
  the start page's and the profile's.
- **The waits go.** `PlaybackViewModel.startRemotely` drops the 600 ms sleep, the revision
  check and the re-copy, and with them its reference to `QueueService`: a call straight after
  the command would run before the cluster reported, and so would only ask for the old queue.
  The reconnect's re-copy goes with its drop-then-rise detection, and so do
  `DeviceService.waitForTransferSettling()` and `lastTransferTime`, which only it read.
- **Tests.** `QueueBootstrapTests` covers `queueUpdate(from:)` and `setQueue`. Its cases (nil,
  empty, history only, providers, uids, rows that are not tracks) move to tests of the derived
  entries, in `QueueTests` (renamed from `QueueBootstrapTests`). New tests cover `hydrate()`
  asking again after a failed fetch and a logout leaving an empty queue.
- **Docs.** `CLAUDE.md`'s *State Management Architecture* names `PlayerModel` as the queue's
  owner and stops listing it under `AppStore`.

To confirm during implementation: what `player.queue` holds across a sleep and a disconnect.
The client sets it to nil only in `shutdownAndCleanup()`, which runs at logout. If a disconnect
publishes an empty queue, the observation already applies it today, so this is no regression;
it is still worth seeing once.

Behavior changes:

- the header and the rows change in the same frame;
- a remote start no longer waits 600 ms to look again;
- missing metadata is asked for again when the network returns, rather than on a session
  reconnect.

### 4. Writes back into the services

- **The library refresh.** `refreshAction(for:)` makes the same call that pull-to-refresh and
  Try again make, `load…(forceRefresh: true)`, and then restores the selection as now, which
  stays a navigation job. The view's resets go: the service resets the pagination itself, and
  the load replaces the id list at offset 0. Moving the emptying into the services'
  `forceRefresh` branch instead would also blank the list on pull-to-refresh and Try again.
  The emptying did one thing besides: it took `LoadMoreRow`'s spinner off screen, so it asked
  again when it came back. The spinner now also asks when the list starts over and when that
  first page lands (`isLoaded`), which serves every refresh path. Not on every change of the
  offset: the spinner, still laid out as a page lands, would then fetch the one after it too.
- **The profile.** One home for the fetch, a small `ProfileService` with two ways in:
  - `require()`, today's `PlaylistService.requireProfile()`: the store's profile, or one
    fetched through the registry. Playlist writes call it and pass its error on.
  - `reload()`, always a request of its own, for the launch and the network's return. The
    launch logs a failure and goes on, as `loadProfile()` does now.

  Not one single-flight path for all three callers: that would make the network-return retry
  join a request the launch started offline and fail with it, which is why
  `plans/done/list-failures-the-retry-cannot-see.md` kept two loaders. It named this split as
  the way to have one.
- **⌘L's favorite toggle.** `PlaybackViewModel` holds the `TrackService` weakly, like the store,
  so a logout does not keep the old account's service and store alive. It is set in the same
  wiring call. `toggleCurrentTrackFavorite()` calls `toggleFavorite(trackId:)` and turns a
  thrown error into `errorMessage` as now, and the now-playing bar's heart calls it too.
- **Tests.** `PlaylistServiceTests`' profile cases stay, now running through `ProfileService`.
  New: a reload does not join a request in flight, and asks even with a profile in the store.
  `LibraryPageFailureTests` keeps recording a failed refresh.

Behavior change: the toolbar's refresh keeps the list on screen until the answer replaces it,
as pull-to-refresh does. A failed one leaves the old list with the error in its last row,
rather than an empty page with the error.

### Follow-ups

Found while building the phases, and each recorded as an open plan of its own:

- `plans/done/playback-view-model-mirrors-the-player.md`
- `plans/open/views-still-write-the-store.md`
- `plans/open/menu-commands-lose-the-session-with-the-window.md`
- `plans/open/ownership-checks-trust-the-launch-profile.md`
- `plans/open/toolbar-refresh-moves-the-selection.md`
- `plans/done/now-playing-bar-missing-on-show-all-tracks.md`

### Not changing

- **One class for the store.** Observation tracks each property separately, so a view reading
  `homeSections` does not update for `tracks`. The size of `AppStore` costs reading time, not
  runtime. Splitting the entity tables from page state (search, start page, pagination) is
  possible later, but it fixes no inconsistency.
- **Invalidation across a whole dictionary.** A view that reads `store.tracks[id]` depends on
  all of `tracks`, so any upsert re-evaluates every such body. `favoriteTrackIds` does the same
  to every visible `TrackRow`. Per-entity `@Observable` objects would narrow that, at the cost
  of identity maps and a second kind of entity. Lists are lazy and nothing has measured slow,
  so this stays until a profile says otherwise.
- **Display fields on entities**, such as `Track.artistName`, `albumName` and `images`,
  `Album.artistName` and `Playlist.ownerName`. They are a summary embedded when the entity was
  fetched, which makes the store normalized in practice rather than strictly. Such a field can
  go stale when Spotify corrects a name, until the entity is fetched again. That is the usual
  trade for not resolving three tables per row. The one entity the app renames itself, a
  playlist, is not embedded in any other.
- **`unplayableTrackUris`.** It is derived but stored on purpose: it is playback's input, and
  it is written only when it changes, from the one method that changes it.
- **`withheldTrackUris`, a copy of `PlayerModel.withheld`.** It is what greys a track that
  reaches the store after playback reported it.
- **`favoriteTrackIds` with `resolvedFavoriteTrackIds`.** These are a three-state value in two
  sets; a `[String: Bool]` would say it directly. All four writers are in one file and keep the
  sets consistent, so it is fine to change in passing, but it is not worth a PR.
- **`PlaybackViewModel`'s own playback fields** (`isPlaying`, `currentTrackUri`,
  `trackDurationMs`, `isShuffleEnabled`). They are mostly copied from `PlayerModel.playback`,
  with local exceptions:
  - `isPlaying` reads the local player while this Mac is the active device;
  - a local start sets the track and `isPlaying` before the player reports them;
  - the duration and the position anchor feed the position clock, which several done plans
    tuned.

  `isShuffleEnabled` is a plain mirror. This is the next duplication worth a plan, but it
  needs a plan of its own and is not folded into this one.
- **`onLogout` through `LoggedInContentRouterView`.** One closure, one level deep, is clearer
  than an environment action.
- **The two singletons.** `PlayerModel.shared` and `PlaybackViewModel.shared` live for the
  whole process, because media keys and the menu commands outlive the window.
- **TCA, Redux-style actions or SwiftData.** The store is a cache of a server, so there is
  nothing to persist, and its mutation methods already are the actions.

## Verification

Each PR was built, unit-tested, linted with `swiftformat --swiftversion 6.4 --lint`, reviewed with
`/simplify` and `/code-review`, and checked live against the Debug build before it was merged.

1. **The view model from the environment (#159).** Every view that lost the argument rendered:
   - each section and detail view, the queue, the toolbar and the mini player;
   - Speakers;
   - a track's context menu, from a row and from the bar's "…", with its playlist submenu.

   ⌘L was tested with #162.
2. **Search results as ids (#160).** A test playlist renamed through Edit Details was renamed
   on its search card too, then renamed back.
3. **The queue read from the player (#161).** These were checked with the silent librespot
   device: its mirrored queue and a skip, a handover in each direction, and a reconnect after
   `SPOTIFLY_DEBUG_DROP_AP_AFTER`. Ralph tested the rest:
   - a sleep and wake, where the queue stayed;
   - Wi-Fi off and on, where the network-return retry asked again;
   - a remote start with `SPOTIFLY_DEBUG_ACCOUNT_TYPE=free`, where the queue showed 0.4 s after
     the command;
   - a logout and sign-in.

   The sleep showed a separate bug, also on `main`: a mirrored position stays behind by the time
   offline. It is fixed on its own.
4. **Writes back into the services (#162).**
   - The launch made one profile request. "Add to new playlist" created a playlist using the
     stored profile.
   - The toolbar's refresh in Playlists, Albums and Artists kept the list and the selection.
   - Liked Songs paged as on `main`, one page per arrival at the bottom. A refresh at the bottom
     of the fully loaded list fetched the first page and then the second.
   - Ralph tested the heart and ⌘L.
