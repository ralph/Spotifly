# A search that fails says nothing

Status: **Done** 2026-10-01. A failed search opens its results page with the error and Try again.
Seen in the running app with a failure injected; see Verification. Split from
`plans/done/list-failures-the-retry-cannot-see.md`.
Components: `Spotifly/Store/AppStore.swift` (`failedSearch`, `searchFailure(for:)`,
`canShowSearch(for:)`), `Spotifly/Store/Services/SearchService.swift`,
`Spotifly/ViewModels/NavigationCoordinator.swift`, `Spotifly/Views/LoggedInContentRouterView.swift`,
`Spotifly/Views/LoggedInView.swift` (`performSearch`, the sidebar's search row)
Found: 2026-09-30, in the review of the network-return retry

## Summary

A submitted search that failed, offline or on a server error, left the app where it was. The
error was kept in `searchErrorMessage`, which only a debug log read. It now opens the search
results page, which says why in their place, with Try again.

## Problem

`performSearch` navigated to the results only when there were some. A failure set
`searchErrorMessage` and nothing else happened: no message, no results, no Try again.

## Solution

- **Where it is said:** the search results page, the place the search would have opened, with
  `InlineLoadError`, as an album or playlist page that has nothing to show. Its Try again runs
  the search again, and so does the network's return while the page shows: the user is still
  looking at it, so it has not been left behind, which was the plan's doubt.
- **The store keeps one failure:** `failedSearch`, the last submitted query that failed and its
  `LoadFailure`. Results for that query replace it. Emptying the field clears it. One slot, not
  the results cache: a failure must not push good results out of the five the cache keeps, nor
  hide cached results for the same query, which the page shows first.
- **Navigation:** a search route can be shown when its query has results or that failure
  (`canShowSearch`), for opening it and for the history. When the failure goes, its routes
  leave the history, as an evicted query's do. The sidebar's search row shows while a failed
  page does, since the selection is there; it reopens to the last results only.

## Verification

- [x] Build, 491 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. Two new
      navigation tests: a failed search opens its page until results replace the failure, and
      its route leaves the history with the failure.
- [x] Live, 2026-10-01, twice, the second time on the final code, with a throwaway build, never
      committed, that submitted "Brian Fallon" at launch and failed its first attempt as
      `URLError(.notConnectedToInternet)`: the page "Suchergebnisse" opened with the error and
      "Erneut versuchen", the sidebar's row selected; Try again sent the four searches and the
      results took the error's place. A real offline failure was not tried: that would mean
      switching the Mac's network off.
- [ ] Emptying the field while the page shows: not seen. The accessibility press on the field's
      clear button emptied it without reaching SwiftUI's binding, so the handler, unchanged by
      this, did not run. Covered by the navigation test.
