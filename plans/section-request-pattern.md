# Section navigation: one request, one pattern, one cache

Branch: `improve-section-nav`

## Symptom

Opening an album in the Albums section often shows the header but no tracks, with a
red `Abgebrochen` (= `URLError.cancelled`) under the disabled play button. The same
class of problem exists in Favorites / Playlists / Artists in weaker forms, because
each section grew its own variant of the same loading code.

## What the log actually shows

```
14:07:15.991 SpotifySession  Returning valid token: BQDxlBtVL2y_76vbgDkc...
14:07:16.010 SpotifySession  Returning valid token: BQDxlBtVL2y_76vbgDkc...
14:07:16.086 SpotifyAPI [GET] /v1/albums/4ifWQZN7li3ij532LR1l0q?fields=...
14:07:16.086 SpotifyAPI [GET] /v1/albums/4ifWQZN7li3ij532LR1l0q/tracks?limit=50&fields=...
```

These are **two different endpoints**, not the same request twice: metadata and
track list, issued in parallel by a single `AlbumService.fetchAlbumDetails`. So this
excerpt is not evidence of a duplicated request — but it *is* evidence of a wasted
one: the album was already in the store (it came from `/me/albums`), so its
metadata did not need fetching at all. Halving this pair is fix #1.

Genuinely duplicated requests are still possible in the current code (see below);
they are just not what this excerpt proves.

## Diagnosis

### 1. Two entry points into one unguarded fetch

`AlbumDetailView.task(id: albumId)` runs two loads back to back:

- `loadAlbum()` → `AlbumService.fetchAlbumDetails` (issues the pair above)
- `loadTracks()` → `AlbumService.getAlbumTracks` → `fetchAlbumDetails` again

In the happy path the second one is a cache hit and issues nothing. But
`loadAlbum()` **catches every error, including cancellation**, and the outer `.task`
then falls through into `loadTracks()` anyway — so a cancelled first load turns
into an immediate second attempt from an already-cancelled context. And each of the
two paths fetches its own token first, which is what the two
`Returning valid token` lines are.

`fetchAlbumDetails` has **no in-flight deduplication at all**. `getAlbumTracks` has
one, but it is a `Set<String>` + 50 ms polling loop that only guards the
`getAlbumTracks` path — `loadAlbum` walks straight past it. `PlaylistService`
already has a proper per-ID `Task` map; `ArtistService` has nothing. Three
sections, three different answers.

### 2. Requests die with the view

Album and artist detail fetches run *structurally inside* the view's `.task`. When
SwiftUI tears the view down, the `URLSession` request is cancelled →
`URLError(.cancelled)` → `error.localizedDescription` → the red `Abgebrochen`.
Nothing retries. (Playlists are already immune: `fetchPlaylistDetails` runs in a
stored unstructured task, so teardown cancels the waiter, not the request.)

Teardown sources, in rough order of likelihood:

- selection change — both `.id(albumId)` and `.task(id: albumId)` force replacement;
- the router's `if/else` between `AlbumDetailView(album:)` and
  `AlbumDetailView(albumId:)` in `LoggedInDetailRouterView`. Those are the two
  branches of a `_ConditionalContent` and therefore have distinct structural
  identities; `.id(albumId)` does not unify them. The branch flips when the album
  first appears in `store.albums` — which happens when *another* producer (library
  page load, recently-played, top items) inserts partial metadata while the detail
  request is in flight;
- the 2-column ⇄ 3-column flip in `LoggedInView.contentRegion`;
- `NavigationStack` pop, section switch, mini-player, logout;
- sibling failure inside the `async let` pair — the two halves are structured
  children, so one failing cancels the other.

A plain `@Observable` body recomputation does *not* cancel a task while structural
and explicit identity hold.

### 3. The polling waiter fails silently

A second caller reaching `getAlbumTracks` while the first is in flight polls
`loadingAlbumTrackIds` every 50 ms. When the first load is cancelled the flag is
cleared by its `defer`, the poll exits, and the waiter returns `[]` — **no error,
no retry**. The album stays empty until the user navigates away and back. This is
"viele Alben laden nicht".

### 4. `tracksLoaded` is not a load marker

`Album.tracksLoaded` / `Playlist.tracksLoaded` are defined as `!trackIds.isEmpty`.
An album or playlist that genuinely has no tracks is therefore re-fetched on every
single visit, forever — and emptying a playlist produces the same state. Any cache
rule built on it inherits the bug.

### 5. Fetched data lives in `@State`, not in the store

The three detail views mirror their entity into `@State`. `ArtistDetailView` also
mirrors the artist's albums into `@State albums`, which is never written to the
store at all — so every artist visit re-requests `/artists/{id}/albums`. All of it
is discarded on teardown and fetched again. `@State` is identity-bound and does not
follow later initialiser values, so the dual `init(album:)` / `init(albumId:)`
shape is a second source of staleness.

### 6. Redundant requests elsewhere

- The detail views' `.task(id: tracks…)` calls `refreshFavoriteStatuses`, which
  deliberately ignores `resolvedFavoriteTrackIds` — so `/me/tracks/contains` is
  re-issued every time the track list changes.
- `PlaylistDetailView`'s reorder-failure path calls `getPlaylistTracks` to "revert
  by reloading", but that returns the optimistically-mutated cached list without
  ever hitting the network.

## Design

One helper, one entry point per entity, all fetched data in `AppStore`.

### `InFlightRequests<Value>` — `Store/Services/InFlightRequests.swift`

```swift
@MainActor
final class InFlightRequests<Value: Sendable> {
    private var running: [String: (id: UUID, task: Task<Value, Error>)] = [:]

    func isRunning(_ key: String) -> Bool
    func run(_ key: String, operation: @escaping @Sendable @MainActor () async throws -> Value) async throws -> Value
    func cancel(_ key: String)   // cancels *and* removes, so the next run() starts fresh
}
```

Documented semantics — each of these is load-bearing:

- **Deduplication.** A second caller for the same key awaits the same `Task`.
- **Cancellation resilience.** The `Task` is *unstructured*, so it does not inherit
  the caller's cancellation. A view torn down mid-flight no longer kills the
  request; the response still lands in `AppStore` and the replacement view reads it
  from there. A cancelled waiter simply stays suspended until the shared task
  finishes. This generalises what `TrackService.favoritesLoadTask` and
  `RecentlyPlayedService.loadTask` already do by hand.
- **One key = one postcondition.** A key may only ever stand for the exact same
  operation. `album:<id>` always means "metadata *and* tracks are in the store".
- **Errors fan out.** All joined callers get the same error; the entry is removed on
  completion, so the next caller retries normally. Call sites must not swallow that
  with `try?` and call it success.
- **`cancel(key)` removes the entry** before returning, so a force refresh cannot
  rejoin the task it just cancelled. The `UUID` stops a cancelled task's `defer`
  from clearing its successor.

Each service owns its own registry, so keys are plain entity IDs (plus one constant
per list load) — no string namespacing to get wrong.

Alongside it, one small free function:

```swift
func isCancellation(_ error: Error) -> Bool   // CancellationError | URLError.cancelled
```

used by the detail views so a cancellation is never rendered as an error message.
Not an extension on `Error` — this is a view-layer presentation rule, not a
universal truth about errors.

### Explicit load markers instead of inference

`Album` and `Playlist` get two stored flags, replacing the derived `tracksLoaded`:

- `detailsLoaded` — the full entity was fetched from a source that returns every
  field the model has (`/albums/{id}`, `/me/albums`, `/playlists/{id}`,
  `/me/playlists`). Entities synthesised from a track's `album` object
  (`TopItemsService`), from `/artists/{id}/albums` or from search results have it
  `false`.
- `tracksLoaded` — the track list was fetched, even if it came back empty.

`upsertAlbum` / `upsertPlaylist` merge monotonically: a partial entity never
downgrades a complete one, and never clears loaded tracks.

`AppStore` also gains `artistAlbumIds: [String: [String]]`, so an artist's albums
are cached the way album/playlist tracks are.

Known limitation, deliberately not fixed here: album tracks and artist albums are
fetched with `limit=50` and no pagination, so for a >50-item album the marker
records "loaded" for a truncated list. That is pre-existing and orthogonal.

### Uniform service API

| Service | Entry point | Key | Requests when everything is cached |
|---|---|---|---|
| `AlbumService` | `ensureAlbumLoaded(albumId:)` | `<id>` | 0 |
| `PlaylistService` | `ensurePlaylistLoaded(playlistId:)`, `reloadPlaylist(playlistId:)` | `<id>` | 0 / always refetches |
| `ArtistService` | `ensureArtistLoaded(artistId:)` | `<id>` | 0 |
| `AlbumService` | `loadUserAlbums(forceRefresh:)` | `user-albums` | 0 |
| `PlaylistService` | `loadUserPlaylists(forceRefresh:)` | `user-playlists` | 0 |
| `ArtistService` | `loadUserArtists(forceRefresh:)` | `user-artists` | 0 |
| `TrackService` | `loadFavorites(forceRefresh:)` | `favorites` | 0 |

`ensureAlbumLoaded` issues `/albums/{id}` only when `!detailsLoaded` and
`/albums/{id}/tracks` only when `!tracksLoaded`. For an album opened from the
library list that is one request instead of two; on a second visit, none.
`ensurePlaylistLoaded` is the same shape. `ensureArtistLoaded` fetches details and
albums, each guarded by its own marker.

`fetchAlbumDetails`, `getAlbumTracks`, `getAlbum`, `fetchArtistDetails`,
`fetchArtistAlbums`, `getArtist`, `fetchPlaylistDetails` and `getPlaylistTracks`
become private or disappear. The four list loads move onto the same helper — they
are four hand-written copies of it today — with pagination semantics unchanged.

### Views read the store

`AlbumDetailView`, `ArtistDetailView`, `PlaylistDetailView`:

- one initialiser, `init(albumId:)`; the `init(album:)` variant and the `@State`
  entity mirrors go away;
- the entity becomes `store.albums[albumId]`, tracks stay store-derived,
  `ArtistDetailView`'s albums come from `store.artistAlbumIds`;
- one `.task(id: albumId) { await load() }` calling the single `ensure…` method, so
  a caught failure can no longer fall through into an accidental retry;
- the router's `if/else` collapses to a single branch, so the view is no longer
  destroyed when the entity appears in the store;
- `PlaylistDetailView` keeps `@State` only for genuine draft input
  (`editingPlaylistName`, `editingPlaylistDescription`); the display-only
  `playlistName` / `playlistDescription` mirrors are dropped in favour of the store.

Reading `store.albums[id]` subscribes the whole body to the `albums` dictionary
rather than to one key. That is already true of these views today (their `tracks`
computed properties read `store.albums` and `store.tracks`), the store is small,
and per-entity observable boxes would be disproportionate here.

### Deliberately out of scope

- **`RecentlyPlayedService` keeps calling `SpotifyAPI` directly.** Routing it
  through `ensureAlbumLoaded` would turn a metadata-only prefetch into a full track
  fetch for every recent album on the startpage. Its results land in the store and
  are now marked `detailsLoaded`, so a detail view opened afterwards skips the
  metadata request — which is the duplication that actually mattered.
- **No in-flight tracking for `/me/tracks/contains`.** Switching the detail views
  from `refreshFavoriteStatuses` to the cache-aware `ensureFavoriteStatuses` is
  enough; a per-batch registry would guard a rare overlap at real complexity cost.
  Queue, search and the now-playing bar keep `refreshFavoriteStatuses` — they are
  outside this branch's scope.
- **Album/artist `limit=50` pagination.** Pre-existing, separate.
- **A stale list response can revert a just-saved playlist name.** `upsertPlaylist`
  replaces metadata, so a `/me/playlists` page captured before an edit can land
  after it. Pre-existing; guarding it properly needs response revisioning, which is
  more machinery than this buys.

## Commits (one per fix)

1. `InFlightRequests` helper + `isCancellation` + tests.
2. Explicit `detailsLoaded` / `tracksLoaded` markers on `Album` and `Playlist`,
   monotonic upsert merging, `artistAlbumIds` cache in `AppStore`.
3. `AlbumService`: `ensureAlbumLoaded` on the helper; skip requests the markers say
   are unnecessary; delete the polling waiter.
4. `PlaylistService`: `ensurePlaylistLoaded` / `reloadPlaylistTracks`; reorder
   rollback actually re-fetches.
5. `ArtistService`: `ensureArtistLoaded` caching artist albums in the store.
6. The four list loads onto the same helper.
7. Detail views store-derived, single initialiser, router conditional collapsed,
   cancellation not surfaced as an error, `ensureFavoriteStatuses`.
8. Superseded runs fenced off the store (`Task.checkCancellation` before writing).
9. `reloadPlaylistTracks` fetches only tracks; a failed rollback is reported.
10. `InlineLoadError` — a retry for a failed track or album list; complete the
    `/albums/{id}` and `/artists/{id}` field projections.
11. Superseded runs stop clearing the replacement's loading state; a reorder
    cancelled by a newer one is not treated as a failure; the shared playlist key
    keeps one postcondition across both entry points.
12. CHANGELOG.

Items 8–11 came out of two review rounds after the first implementation. The
recurring shape: cancellation is cooperative, so a request that has been replaced
still has queued work that will happily write as though it were current.

## Verification

- `xcodebuild -scheme Spotifly -configuration Debug build`
- `xcodebuild -scheme Spotifly test` for the new `InFlightRequests` tests
- `swiftformat --swiftversion 6.3` on touched files only
- Manual, with the debug log open: open an album from the library list, from an
  artist page, from the startpage recents and from search. Each must produce
  exactly one `/albums/{id}/tracks` line, plus `/albums/{id}` only when the album
  was not already fully known; re-opening the same album must produce none.
