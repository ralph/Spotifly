# A route's drill-down path was an array the app no longer needed

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/Models/Route.swift`, `Spotifly/Models/NavigationDestination.swift` (deleted),
`Spotifly/ViewModels/NavigationCoordinator.swift`, `Spotifly/Views/LoggedInContentRouterView.swift`,
`Spotifly/Views/SearchResultsView.swift`, `SpotiflyTests/NavigationCoordinatorTests.swift`
Found: 2026-10-02, in the review of `plans/done/now-playing-bar-missing-on-show-all-tracks.md`

## Summary

`Route.path` was an array of `NavigationDestination` because a `NavigationStack` used to draw it.
The stack was gone: the router drew only the path's last entry, and the only push in the app was
search's "show all tracks". "Show all tracks" is now a page of the search route,
`Route.showsAllTracks`, and the path and `NavigationDestination` are gone.

## Problem

- **Only `.last` was drawn.** Each push already recorded the whole previous route in the
  history's back stack, so the earlier entries were a second history inside the first. They
  still took part in `Route` equality and in `isViewable`: a playlist deleted anywhere in a
  route's path dropped the route, though the page never showed it.
- **`.artist`, `.album` and `.playlist` were pushed only by the tests.** Opening one from search
  or a page goes through the sections' ephemeral selections (`Route(showing:)`). The router's
  `destinationView(for:)` and the coordinator's `title(for:)` still routed all three, a second,
  untested way to show the same pages.
- **`.searchTracks(ids:)` copied the search's ids into the route.** The route's `query` already
  reached them through `store.searchResults(for:)`, and the copy could disagree with it. The
  router also checked the path before the search's results and failure, so the search's own
  state did not govern the page drawn from it.

## Solution

- **`Route.showsAllTracks`**, a flag on the search route, in place of `path`. Equality and the
  history work as before: "show all" is a step of its own, and Back returns to the results.
- **`NavigationCoordinator.showAllSearchTracks()`**, in place of `push(_:)`. It does nothing
  outside a search route; on the all-tracks page itself the route is unchanged, so no step is
  added.
- **The router draws both pages from the search's results**: the all-tracks page reads
  `searchResults.trackIds` through the route's query, after the same results-or-failure check
  as the results page, so a failure governs both.
- **`title(for:)`** names the page "Tracks" (`section.tracks`) and otherwise the selection or
  the section, as before. `isViewable` lost the path's deleted-playlist check, which only the
  test-only pushes could reach.
- **The sidebar's search row** reopens the results page, not "show all", as before.

`NavigationCoordinatorTests` used `push(.artist…)` as a generic drill-down. Those steps are now
`navigateToArtistSection`, or a search and its "show all".

## Verification

### Live (2026-10-02)

A throwaway hook, not committed, searched for "Rodriguez" through the view's `performSearch`,
and another logged the coordinator's moves.
- "Alle 20 Tracks anzeigen" opened the Tracks page, 20 tracks, with the now-playing bar below it.
- The toolbar's Back went to the results (`restore … showsAllTracks: false`), and Forward to the
  Tracks page again (`showsAllTracks: true`).

The first tries seemed to skip the results both ways. Those clicks reached the toolbar as raw
input, which moved two steps per click; through accessibility each moved one, as the log shows.

### Unit tests

611 pass. Four are new: "show all" is a step of its own with Back to the results; it opens only
from a search; the sidebar's search row reopens the results; and a selection missing from the
store is named by its section, which the old missing-artist drill-down test covered.
