# Loads that failed offline wait for a retry nobody makes

Status: **Done** 2026-09-30, for the loads that fail offline. Built, linted and unit-tested; not
seen with the network actually dropped, which needs Wi-Fi off; see Verification. Failures while
the network stays up moved to `plans/open/loads-that-fail-while-online.md`.
Components: `Spotifly/NetworkMonitor.swift` (`retryingWhenNetworkReturns`),
`Spotifly/Views/LoggedInLifecycleModifier.swift` (the start page and `loadProfile`),
`Spotifly/Views/LibraryListView.swift`, `Spotifly/Views/FavoritesListView.swift`,
`Spotifly/Views/Components/InlineLoadError.swift`,
`Spotifly/Views/Components/RetryingAsyncImage.swift`
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
time the network comes back while a condition holds. Everything that followed the network by
hand now goes through it.
- **On a Try again button**, which is there only while its error shows, the button's presence
  is the condition, and the retry is what the button does: `InlineLoadError`, a library list's
  and Favorites' full-page error. A failed later page is left to the next scroll, as before.
- **At app level**, in `LoggedInLifecycleModifier`, where the two launch loads start: the start
  page while `store.homeErrorMessage` is set, and the profile while `store.userProfile` is nil.
  Not on the start page itself, which may not be on screen when the network returns. A return
  while the launch's profile request is still out sends a second; skipping it, as a first
  version did, lost the only retry when the first then failed.
- **Artwork**, `RetryingAsyncImage`, while its image has not arrived.

### Left for later

From the reviews; see `plans/open/list-failures-the-retry-cannot-see.md`: a toolbar refresh
offline shows a list's empty state, not its error; a failed later page; search errors, which
are never shown; and the two profile loaders.

## Verification

- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. The modifier is
      view code, not unit-tested; `NetworkMonitor`'s count of returns is.
- [ ] Live: launch with Wi-Fi off. The start page shows its error, and the sidebar no avatar.
      Go to another section, turn Wi-Fi on without pressing anything, and go back: the start
      page has loaded, and the avatar is there.
- [ ] Live: with Wi-Fi off, open Albums, Playlists, Artists and Favorites for the first time this
      launch. Each shows its error. Turn Wi-Fi on: each loads by itself.
