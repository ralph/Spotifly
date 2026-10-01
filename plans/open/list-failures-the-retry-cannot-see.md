# List failures the network-return retry cannot see

Status: **Open**, not planned. From the altitude review of
`plans/done/failed-loads-wait-for-try-again.md`; read from the code, nothing observed.
Components: `Spotifly/Views/LoggedInView.swift` (`refreshAction`), `Spotifly/Store/AppStore.swift`
(`loadLibraryPage`, `PaginationState`), `Spotifly/Views/LibraryListView.swift`,
`Spotifly/Views/FavoritesListView.swift`, `Spotifly/Store/Services/SearchService.swift`,
`Spotifly/Store/Services/PlaylistService.swift` (`requireProfile`)
Found: 2026-09-30, in the review of the network-return retry

## Summary

The retry follows the failures the views show. Some failures are not shown, or not where it
looks.

## Problem

- **A toolbar refresh offline.** `refreshAction` clears a list's ids, then loads with `try?`.
  Offline, the list shows its empty state ("no playlists") instead of its error, and the view's
  `errorMessage` stays nil, so nothing asks again. Two callers load a list, and only one records
  a failure. A failure on `PaginationState`, set and cleared in `AppStore.loadLibraryPage`, the
  one path all four lists share, would let both views read it.
- **A failed later page.** The loading row at the end stays, and its `onAppear` does not fire
  again, so "the next scroll" means scrolling away and back.
- **Search.** `SearchService` sets `searchErrorMessage`, which only a debug log reads. The error
  is not shown at all; retrying a submitted search by itself is doubtful anyway.
- **Two profile loaders.** `LoggedInLifecycleModifier.loadProfile` and
  `PlaylistService.requireProfile` both fetch the profile; only the second shares a request in
  flight (`profileRequests`).

## Solution

Not planned. The first two by a failure on `PaginationState`; search by showing its error first.

## Verification

Not defined yet.
