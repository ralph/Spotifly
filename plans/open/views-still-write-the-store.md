# Some views still write the store, or decide what a load means

Status: **Open**, not planned. The rest of the writes moved into services in
`plans/open/state-held-twice.md`, phase 4
Components: `Spotifly/Views/LoggedInView.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`,
`Spotifly/Views/PlaylistDetailView.swift`, `Spotifly/Store/Services/SearchService.swift`,
`Spotifly/Store/Services/TrackService.swift`
Found: 2026-10-02, in the review of that phase

## Summary

Services own the store's writes, with a few exceptions left in views. Each is small, and
together they are why `AGENTS.md` cannot yet say that views do not write the store.

## Problem

- **Search failure.** `LoggedInView` calls `store.clearSearchFailure()` when the field is
  emptied, while `SearchService` sets the failure. The failure's lifecycle is split between a
  view and a service.
- **Withheld tracks.** `LoggedInLifecycleModifier` passes `player.withheld` into
  `store.setWithheld(_:)` from an `.onChange`. It syncs the player into the store, the kind of
  job `QueueService` does by observing the player.
- **Playlist reorder.** `PlaylistDetailView`'s drop delegate moves rows with
  `store.movePlaylistTrack` for visual feedback while dragging.
- **Favorites recovery.** `LoggedInView.ensureFavoritesLoadedForSelection` re-derives the
  "loaded but empty" recovery rule that `TrackService.loadFavorites` already applies. The two
  copies already differ: the view's version does not check `isLoaded`. It is also a second
  trigger beside `FavoritesListView`'s own `.task`.

## Solution

Not planned. Each is about a one-line move into the service that owns the fact. The reorder may
stay as an optimistic UI write if a service method would only wrap it.

## Verification

None yet.
