# A route's drill-down path is an array the app no longer needs

Status: **Open**, not planned
Components: `Spotifly/Models/Route.swift`, `Spotifly/Models/NavigationDestination.swift`,
`Spotifly/ViewModels/NavigationCoordinator.swift`, `Spotifly/Views/LoggedInContentRouterView.swift`,
`SpotiflyTests/NavigationCoordinatorTests.swift`
Found: 2026-10-02, in the review of `plans/done/now-playing-bar-missing-on-show-all-tracks.md`

## Summary

`Route.path` is an array of `NavigationDestination` because a `NavigationStack` used to draw it.
The stack is gone: the router draws only the path's last entry, and the only push in the app is
search's "show all tracks". The array, three of the four destination kinds, and a copy of the
search's track ids in the route are left over from that design.

## Problem

- **Only `.last` is drawn.** Each push already records the whole previous route in the history's
  back stack, so the earlier entries are a second history inside the first. They still take part
  in `Route` equality and in `isViewable`: a playlist deleted anywhere in a route's path drops the
  route, even though the page never shows it.
- **`.artist`, `.album` and `.playlist` are pushed only by the tests.** Opening one from search or
  a page goes through the sections' ephemeral selections (`Route(showing:)`). The router's
  `destinationView(for:)` and the coordinator's `title(for:)` still route all three, which leaves a
  second, untested way to show the same pages.
- **`.searchTracks(ids:)` copies the search's ids into the route.** The route's `query` already
  reaches them through `store.searchResults(for:)`, and the copy can disagree with it. The router
  also checks the path before the search's results and failure, so the search's own state does not
  govern the page drawn from it.

## Solution

Not planned. Probably: make "show all tracks" a page of the search route, a flag or a small
`SearchPage` enum on `Route` read in the router's search branch, and delete `path` and
`NavigationDestination`. Most of `NavigationCoordinatorTests` uses `push(.artist…)` as a generic
drill-down to test history, so those tests need a search route instead.

## Verification

None yet.
