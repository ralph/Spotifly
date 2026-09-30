# List failures the network-return retry cannot see

Status: **Done** 2026-10-01 for the lists, unit-tested; offline behaviour not seen, see
Verification. Search is `plans/open/search-failure-not-shown.md`; the two profile loaders stay, see
Solution. Stacked on the network-return retry (`plans/done/failed-loads-wait-for-try-again.md`).
Components: `Spotifly/Store/Entities.swift` (`PaginationState.failure`), `Spotifly/Store/AppStore.swift`
(`loadLibraryPage`), `Spotifly/Views/LibraryListView.swift`, `Spotifly/Views/FavoritesListView.swift`,
`Spotifly/Views/Components/LoadMoreRow.swift`, `Spotifly/Views/Components/InlineLoadError.swift`
(`LoadFailure`)
Found: 2026-09-30, in the review of the network-return retry

## Summary

The retry follows the failures the views show. Some failures were not shown, or not where it
looked. A library list's failure is now recorded where every caller that loads the list leaves
it.

## Problem

- **A toolbar refresh offline.** `refreshAction` clears a list's ids, then loads with `try?`.
  Offline, the list showed its empty state ("no playlists") instead of its error, and the view's
  `errorMessage` stayed nil, so nothing asked again. Two callers load a list, and only one
  recorded a failure.
- **A failed later page.** The loading row at the end stayed, and its `onAppear` did not fire
  again, so "the next scroll" meant scrolling away and back.
- **Search.** `SearchService` sets `searchErrorMessage`, which only a debug log reads. Not done
  here; see the open plan.
- **Two profile loaders.** `LoggedInLifecycleModifier.loadProfile` and
  `PlaylistService.requireProfile` both fetched the profile; only the second shared a request in
  flight (`profileRequests`).

## Solution

- **`PaginationState.failure`**: a `LoadFailure`, as the detail pages keep one, set in
  `AppStore.loadLibraryPage`, the one path all four lists share, and cleared when the list's
  next load starts or it is reset. A run a refresh cancelled records nothing (`isCancellation`).
- **The list views read it** instead of an `errorMessage` of their own. With nothing to show, the
  full-page error and its Try again, which the network's return presses too.
- **`LoadMoreRow`**, shared by both views: the spinner that loads the next page, or, once that
  page failed, `InlineLoadError`, whose Try again loads it again, also when the network returns.

### Not done

- **The two profile loaders stay.** Sharing `requireProfile`'s request would make the
  network-return retry join a request the launch started offline, and fail with it: the reason
  the retry's own review removed an in-flight guard from the profile. A retry that starts a fresh
  request, as a list's refresh cancels and restarts, would allow one loader; it belongs with a
  profile of its own rather than inside `PlaylistService`.

## Verification

- [x] Unit tests (`LibraryPageFailureTests`):
  - a failed page is recorded, and the next load clears it;
  - a reset clears it;
  - a cancelled run records nothing;
  - a forced refresh that fails, as the toolbar's does with `try?`, leaves its failure for the
    list.
- [x] Build, 472 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Offline, by hand, with the network-return retry it is stacked on:
  - Wi-Fi off, the toolbar's refresh on Playlists shows the error, not "no playlists";
  - Wi-Fi on again, the list comes back by itself.
  - With a long list (Favorites), Wi-Fi off before scrolling to its end: the end shows the error
    and Try again, and the list goes on by itself when Wi-Fi returns.
