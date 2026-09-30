# Loads that failed offline wait for a retry nobody makes

Status: **Done** 2026-09-30, for the loads that fail offline. Built, linted and unit-tested; not
seen with the network actually dropped, which needs Wi-Fi off; see Verification. Failures while
the network stays up moved to `plans/open/loads-that-fail-while-online.md`.
Components: `Spotifly/NetworkMonitor.swift` (`retryingWhenNetworkReturns`),
`Spotifly/Views/StartpageView.swift`, `Spotifly/Views/LibraryListView.swift`,
`Spotifly/Views/FavoritesListView.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`
(`loadProfile`), `Spotifly/Views/Components/InlineLoadError.swift`
Found: 2026-09-29, in the altitude review of the artwork fix

## Summary

Artwork and the album, artist and playlist pages already loaded again by themselves when the
network came back (`NetworkMonitor`, #98). The start page, the library lists, Favorites and the
profile at launch still waited for a manual retry, or for nothing at all. Now they ask again too.

## Problem

- **The start page.** Its error offered a retry through `homeService.refresh()`, pressed by hand.
- **The library lists and Favorites.** `LibraryListView` and `FavoritesListView` show their own
  error with Try again, or pull-to-refresh; neither is `InlineLoadError`, so neither followed the
  network.
- **The profile at launch.** `LoggedInLifecycleModifier.loadProfile` swallows a failure. Launched
  offline, the app had no profile, so no avatar URL: `RetryingAsyncImage` never got a url to ask
  again, and the sidebar showed initials, or an empty circle, until the next launch.

## Solution

One modifier, `retryingWhenNetworkReturns(if:_:)` beside `NetworkMonitor`, runs a retry each
time the network comes back while a condition holds. `InlineLoadError` now uses it too, with
`failure.canRetry` as the condition, so there is one way to follow the network.
- **The start page**: while `store.homeErrorMessage` is set, `homeService.refresh()`.
- **A library list**: while its error shows, which is when the list has nothing to show,
  `loadItems(forceRefresh: true)`, what Try again does. A failed later page is left to the next
  scroll, as before.
- **Favorites**: the same, with `loadFavorites(forceRefresh: true)`.
- **The profile**: while `store.userProfile` is nil, `loadProfile()` again; the avatar follows.

## Verification

- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. The modifier is
      view code, not unit-tested; `NetworkMonitor`'s count of returns is.
- [ ] Live: launch with Wi-Fi off. The start page shows its error, and the sidebar no avatar.
      Turn Wi-Fi on without pressing anything: within a few seconds the start page loads and the
      avatar appears.
- [ ] Live: with Wi-Fi off, open Albums, Playlists, Artists and Favorites for the first time this
      launch. Each shows its error. Turn Wi-Fi on: each loads by itself.
