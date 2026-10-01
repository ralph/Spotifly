# The end of a list sits under the now-playing bar

Status: **Open**, not planned. Seen by hand on 2026-10-01, testing `plans/done/list-failures-the-retry-cannot-see.md`.
Components: `Spotifly/Views/FavoritesListView.swift`, `Spotifly/Views/LibraryListView.swift`,
`Spotifly/Views/SearchResultsView.swift`, `Spotifly/Views/SearchAllTracksView.swift`,
`Spotifly/Views/Components/LoadMoreRow.swift`, `Spotifly/Views/LoggedInView.swift` (the bar's overlay)
Found: 2026-10-01, in the manual test of the list failures, Wi-Fi off, at the end of Favorites

## Summary

The now-playing bar floats over the bottom of the content (`LoggedInView`'s
`.overlay(alignment: .bottom)`), and some lists leave no room for it. At the end of Favorites
offline, the failed page's message and its Try again sat under the bar, so Try again could not be
clicked. The network-return retry still asked again by itself.

## Problem

- **Which views leave room:** the album, artist and playlist pages (`.padding(.bottom, 100)`), the
  queue and the start page (`.contentMargins(.bottom, 100)`).
- **Which do not:** Favorites, the library lists, search results, and search's all-tracks
  view. Their last row, or `LoadMoreRow`'s error with its Try again, can end under the bar.
- **The clearance is written out five times** as `100`, in two different modifiers.

## Solution

Not planned. Likely `.contentMargins(.bottom, …)` on the four scroll views, with the bar's
clearance named once, for example on `NowPlayingBarView`, and the five existing sites using it.

## Verification

Not defined yet. By hand: scroll each of the four views to its end, with the bar showing a track.
The last row, and offline the end of Favorites with its Try again, is above the bar and can be
clicked.
