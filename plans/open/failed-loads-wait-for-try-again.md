# Loads that failed offline wait for a retry nobody makes

Status: **Open**, not planned. Read from the code in the review of
`plans/done/artwork-stuck-after-network-drop.md`; nothing observed.
Components: `Spotifly/Views/StartpageView.swift` (the home error), `Spotifly/Views/LibraryListView.swift`,
`Spotifly/Views/FavoritesListView.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`
(`loadProfile`), `Spotifly/NetworkMonitor.swift`, `Spotifly/Views/Components/RetryingAsyncImage.swift`
Found: 2026-09-29, in the altitude review of the artwork fix

## Summary

Artwork and the album, artist and playlist pages now load again by themselves when the network
comes back (`NetworkMonitor`). Other loads that failed offline still wait for a manual retry, or
for nothing at all.

## Problem

- **The start page.** Its error offers a retry through `homeService.refresh()`, pressed by hand.
- **The library lists and Favorites.** `LibraryListView` and `FavoritesListView` show their own
  error with Try again, or pull-to-refresh; neither is `InlineLoadError`, so neither follows the
  network.
- **The profile at launch.** `LoggedInLifecycleModifier.loadProfile` swallows a failure. Launched
  offline, the app has no profile, so no avatar URL: `RetryingAsyncImage` never gets a url to ask
  again, and the sidebar shows initials, or an empty circle, until the next launch.
- **Failures while the network stays up.** A server error, or a captive portal, fails an image or
  a page while `NWPathMonitor` reports the path satisfied throughout. Nothing counts as a return,
  so artwork keeps its placeholder until the view is rebuilt, and a page waits for Try again as
  it always did.

## Solution

Not planned. The first three can follow `NetworkMonitor.shared.returns` as `InlineLoadError` does,
the profile by loading again on a return when it has none. The last would need a retry that does
not depend on the network, with a backoff, and only for failures that may pass: an image a CDN
answers 404 for would otherwise be asked for forever.

## Verification

Not planned.
