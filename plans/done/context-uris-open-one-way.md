# A context's uri is turned into a page in two places

Status: **Done** 2026-09-30, for the mapping. Built and unit-tested; see Verification. The other
half of the plan, this Mac naming its own context to the cluster, moved to
`plans/open/own-context-name-not-reported.md`.
Components: `Spotifly/Models/Route.swift` (`Route(contextUri:)`),
`Spotifly/ViewModels/NavigationCoordinator.swift` (`open(_:)`), `Spotifly/Views/QueueListView.swift`
(`contextInfo`), `Spotifly/Views/LoggedInLifecycleModifier.swift` (`SPOTIFLY_DEBUG_OPEN`)
Found: 2026-09-30, in the altitude review of `plans/done/queue-header-names-no-liked-songs.md`

## Summary

The queue header and the `SPOTIFLY_DEBUG_OPEN` hook each turned a context uri into a page, and
only the header knew that Liked Songs is Favorites. Now both use `Route(contextUri:)`.

## Problem

- The queue header had its own `ContextLink` and `navigate(to:)`, one case per kind, and the
  Liked Songs special case.
- `SPOTIFLY_DEBUG_OPEN` had its own chain of `SpotifyURI.id(from:kind:)` calls, and would have
  opened `LikedSongs.uri` as a playlist page.
- The next link from a uri, such as the now-playing bar's context or a deep link, would have made
  a third.

## Solution

- `Route(contextUri:)`, beside `Route`, maps an album, artist or playlist uri to its section and
  selection, `LikedSongs.uri` to Favorites, and anything else to nil.
- `NavigationCoordinator.open(_:)` opens a route made elsewhere.
- The queue header takes its link from the route and its own name from the route's selection,
  or, for Liked Songs, the section's title. `ContextLink` is gone.
- `SPOTIFLY_DEBUG_OPEN` opens whatever route the uri gives.

## Verification

- [x] Unit tests: an album, an artist and a playlist open their pages; Liked Songs opens
      Favorites; a station, a collection uri and a malformed uri open nothing.
- [x] Build, 464 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
