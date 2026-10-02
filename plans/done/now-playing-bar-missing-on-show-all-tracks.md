# The now-playing bar is missing on search's "show all" tracks page

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/Views/LoggedInContentRouterView.swift`, `Spotifly/Views/SearchResultsView.swift`,
`Spotifly/ViewModels/NavigationCoordinator.swift`, `Spotifly/Models/NavigationDestination.swift`,
`SpotiflyTests/NavigationCoordinatorTests.swift`
Found: 2026-10-02, live-checking `plans/done/state-held-twice.md`, phase 1; the same on `main`

## Summary

On the search results page the bar shows, overlaid on the content region. After "Alle 20 Tracks
anzeigen", which pushed `SearchAllTracksView` onto the content router's `NavigationStack`, it was
gone, and the accessibility tree had none of its buttons either. The split view's detail column
took the push over and showed the pushed page in place of the whole column, so everything laid
around the router went with it. The router now draws the drill-down itself, from the
coordinator's route, and the `NavigationStack` is gone.

## Problem

### Seen

On a build of `main`, with a search for "Rodriguez" and a 1400×846 window:

- **The bar:** gone on the pushed page, and none of its buttons in the accessibility tree.
- **The room under the page:** scrolled to the end, row 20 sat on the window's bottom edge. The
  `contentMargins(.bottom, NowPlayingBarView.contentClearance)` beside the bar's overlay did not
  reach the page either.
- **The content toolbar:** the history's back and forward control was gone. In its place was the
  stack's own back chevron.
- An artist opened from the same results kept the bar. It opens as the Artists section's
  ephemeral selection, not as a push.

### Why

A probe build put a label in three places: on the stack's root page, on the `NavigationStack`
itself, and on `contentRegion` in `LoggedInView` beside the bar. On the search results page all
three showed. On the pushed page **none** did, not even the one on the `NavigationStack`. So the
pushed page was not drawn inside the stack's frame. The `NavigationSplitView`'s detail column took
the push over and showed the page in place of the column's whole content, and every modifier
between the column and the stack went with it:

- the bar's overlay and the room under each page (`contentRegion`);
- the content toolbar, with the history's back and forward control (`contentRouter`);
- the two playback alerts on `contentRegion`: the Premium notice and the request to authorize
  streaming. A play from the page's "Play tracks" button that needed one could not show it.

The push was the app's only one. Since the drill-downs from detail pages became the sections'
ephemeral selections, "show all" in search was the only place a `NavigationDestination` was
pushed; the `.artist`, `.album` and `.playlist` cases are pushed only by the coordinator's tests.

## Solution

**The router draws the route's last drill-down itself.** `LoggedInContentRouterView` shows
`destinationView(for:)` for `navigationCoordinator.navigationPath.last`, and the section's page when
the path is empty. The results' "show all" is a button that calls `navigationCoordinator.push`.
The page is drawn where the section pages are, inside `contentRegion`, so it has the bar, the room
under it, the toolbar and the alerts like any other page.

**The coordinator is the only owner of the path.** `plans/done/navigation-one-location-value.md`
kept `NavigationStack` as the drill-down renderer, and reconciled it with the coordinator's
history: `setNavigationPath` sorted the stack's writes into pushes and pops, and
`historyRestoreTarget` swallowed the write the stack sent back after the coordinator changed the
path. With no stack, nothing writes the path but `push`, so all of that is gone:
`setNavigationPath`, `navigateBackward(to:)`, `isDescendant(_:of:)` and `historyRestoreTarget`, with
the four tests of the stack's pops. `navigationPath` is read-only, and `push` navigates to the
route with the destination appended.

**What changes for the user, besides the bar:** the pushed page's back chevron is replaced by the
history's back and forward control, which the toolbar shows on every other page. Back from "show
all" redraws the results page, so it opens scrolled to the top. The "show all" link sits in the
first section, at the top.

**Considered and not done:**
- **The bar, the room and the alerts on the destination too:** the 2-column case would have
  needed the same modifiers in two places, and the toolbar and the alerts would still have needed
  copying. The cause, the column taking the push, would have stayed.
- **A container around the stack to stop the column taking it over:** if one works, it rests on
  undocumented behaviour, and the app would still have kept two owners of the path.

## Verification

- [x] **Reproduced on `main`**, then explained with the probe labels above.
- [x] **Live, on the fix:**
  - search, "Alle 20 Tracks anzeigen": the bar shows, the title is "Tracks", and the toolbar has the
    history's back and forward control;
  - scrolled to the end: row 20 clears the bar;
  - back returns to the results, and forward to the tracks page again;
  - Start page, Favorites, Playlists, Albums, Artists (the 3-column ones with their detail), Queue,
    Speakers and Profile: each shows its title, its content and the bar as before.
- [x] Unit tests: `NavigationCoordinatorTests`, with `a drill down records history` in place of the
      stack's tests.
