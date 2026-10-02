# Some views still wrote the store, or decided what a load means

Status: **Done** 2026-10-02, verified live, except the search failure, which is unit-tested
Components: `Spotifly/Views/LoggedInView.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`,
`Spotifly/Views/PlaylistDetailView.swift`, `Spotifly/Store/Services/SearchService.swift`,
`Spotifly/Store/Services/QueueService.swift`, `Spotifly/Store/Services/PlaylistService.swift`,
`AGENTS.md`
Found: 2026-10-02, in the review of `plans/done/state-held-twice.md`, phase 4

## Summary

Services own the store's writes, and four exceptions were left in views. Each now goes through
the service that owns the fact, and `AGENTS.md` says that views do not write the store.

## Problem

- **Search failure.** `LoggedInView` called `store.clearSearchFailure()` when the field was
  emptied, while `SearchService` set the failure. The failure's lifecycle was split between a
  view and a service.
- **Withheld tracks.** `LoggedInLifecycleModifier` passed `player.withheld` into
  `store.setWithheld(_:)` from an `.onChange`. It synced the player into the store, the kind of
  job `QueueService` does by observing the player.
- **Playlist reorder.** `PlaylistDetailView`'s drop delegate moved rows with
  `store.movePlaylistTrack` for visual feedback while dragging.
- **Favorites recovery.** `LoggedInView.ensureFavoritesLoadedForSelection` re-derived the
  "loaded but empty" recovery rule that `TrackService.loadFavorites` already applies. The two
  copies differed: the view's version did not check `isLoaded`. It was also a second trigger
  beside `FavoritesListView`'s own `.task`.

## Solution

- **Search failure:** `SearchService.clearFailure()`, which the view calls when the field is
  emptied.
- **Withheld tracks:** `QueueService.activate()` observes `player.withheld` with `Observations`,
  beside the queue, and passes each value to `store.setWithheld`. The first value is the
  player's set as it stands, which is what `.onChange(initial: true)` gave a new login's store.
  A non-empty set is logged (`Playback found N withheld, greying them`).
- **Playlist reorder:** `PlaylistService.previewMove(playlistId:fromIndex:toIndex:)`. It only
  wraps the store's move, which the plan allowed to stay in the view. It is a method anyway, so
  the rule in `AGENTS.md` needs no exception, and the service owns both the order shown while
  dragging and the move it sends on the drop.
- **Favorites recovery:** the view's copy and its `.onChange(of: selectedNavigationItem)` are
  gone. `FavoritesListView`'s `.task` loads when the list is empty, and
  `TrackService.loadFavorites` applies the recovery rule itself, so entering Favorites does
  what it did. The `.task` also covers a launch that restores Favorites, which the
  `.onChange` never saw.

Left as is, since neither writes the store:
- The other direction of the withheld sync, `store.unplayableTrackUris` to
  `SpotifyPlayer.setUnplayable`, stays an `.onChange` in `LoggedInLifecycleModifier`. It writes
  the player.
- `NavigationCoordinator` records the search the page last showed
  (`store.markSearchQueryDisplayed`). `AGENTS.md` names it as the one writer outside the
  services.

A search of `Spotifly/Views` and `Spotifly/ViewModels` for calls to `AppStore`'s methods and for
assignments to its properties found no other write.

## Verification

### Live (2026-10-02)

- **Withheld tracks:** a throwaway hook, not committed, started Liked Songs at "Girlfriend (feat.
  Dâm-Funk)", which Spotify withholds here and which the app had not listed. The player loaded
  it, found no files, skipped to "Tilted", and in the same millisecond `QueueService` logged
  `Playback found 1 withheld, greying them`. The app was quit about a second into "Tilted".
- **Favorites:** Navigation → Favoriten loaded the list with one `fetchPlaylistContents`.
- **Playlist reorder:** in "Spotifly test: 1007 tracks", Kapitel 1 dragged onto Kapitel 3 moved
  while dragging. The drop sent `moveItemsInPlaylist`, and the reload that follows showed 2, 3,
  1, 4. Dragging it back sent a second move, and the reload showed 1 to 5 in order again.

### Unit tests

589 pass, one of them new and one changed:
- `the queue service passes the player's withheld tracks to the store`: a `PlayerModel` with a
  withheld track greys it in the store at activation, and a second one when the player adds it.
- `a failed search leaves the history with its failure` now clears the failure through
  `SearchService.clearFailure()`, the call the view makes.

Not checked live: clearing a failed search. Making a search fail needs the network down.
