# The playlist view builds its rows once per row

Status: **Done** 2026-09-29. Measured in a hosted view, before and after. Not yet seen in the
running app; see Verification.
Components: `Spotifly/Views/PlaylistDetailView.swift` (`rows`, `normalTrackList`),
`Spotifly/Views/FavoritesListView.swift`, `Spotifly/Views/QueueListView.swift`,
`Spotifly/Views/AlbumDetailView.swift`, `Spotifly/Views/SearchAllTracksView.swift`
Found: 2026-09-29, in the efficiency review of #79

## Summary

A playlist of 2,000 tracks took 10.6 s to lay out. Two costs added up. Every row read the whole
list again to decide whether a divider followed it, and the list built every row up front,
not just the ones on screen. Now the divider goes above each row but the first, so no row
reads the list, and the playlist's list is lazy. The same playlist lays out in 0.05 s.

## Problem

### The list read once per row

`PlaylistDetailView.rows` is a computed property: it maps every playlist item to its track,
looking each up in `store.tracks`. `normalTrackList` read it once for its `ForEach`, and again
inside every row, for `rows.count` in the divider check. So one pass over n tracks built the
array about 2n times: O(n²) lookups, and one array allocation per row.

Four other lists had the same check against a computed list:

| View | List read in every row | Stack |
|---|---|---|
| `PlaylistDetailView` | `rows` | `VStack` |
| `FavoritesListView` | `store.favoriteTracks` | `LazyVStack` |
| `QueueListView` | `allQueueItems` | `LazyVStack` |
| `AlbumDetailView` | `tracks` | `VStack` |
| `SearchAllTracksView` | `tracks` | `VStack` |

A lazy stack builds only the rows on screen, so there it cost one list per visible row: 33
builds of Liked Songs for one layout, whatever its length. Albums and the search list are
short: search shows 20 tracks.

### Every row built up front

With the list read once, a 2,000-track playlist still took 5.1 s. That part grew linearly,
about 2.5 ms a row: the playlist's `VStack` built every `TrackRow`, where Liked Songs, in a
`LazyVStack`, built only the rows on screen.

## Solution

1. **The divider goes above each row but the first** (`if index > 0`), in all five lists. No
   row reads the list's count any more, so none can rebuild it. Same lines on screen.
2. **The playlist's track list is a `LazyVStack`.** It sits inside the page's `VStack` under
   the header, in the same `ScrollView`, and still loads lazily. Albums and search stay eager:
   they are short.

Not changed: the playlist view still reads `tracks`, which maps `rows`, about six times per
pass (the header's count and duration, the play button, the favourites task's id). Each is
O(n), not per row, and the lazy list does not depend on them.

## Verification

- [x] Measured with a throwaway test that hosts the real `PlaylistDetailView` and
      `FavoritesListView` in an `NSHostingView` of 900 × 700 points, with the store filled
      with n tracks, and counts builds of the list. Debug build, 2026-09-29. First layout:

      | | builds | layout |
      |---|---|---|
      | Playlist, 2,000 tracks, before | 4,010 | 10.6 s |
      | Playlist, 2,000, divider moved | 10 | 5.1 s |
      | Playlist, 2,000, and lazy | 10 | 0.05 s |
      | Playlist, 200, before | 410 | 0.53 s |
      | Playlist, 200, after | 10 | 0.04 s |
      | Liked Songs, 2,000, before | 33 | 0.07 s |
      | Liked Songs, 2,000, after | 3 | 0.04 s |

      The test was not kept: it needs a counter in the view's code.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, 2026-09-29.
- [ ] Live: open the largest playlist in the library. The tracks appear without a pause, and
      scrolling to the bottom and back is smooth. Dividers sit between rows, none above the
      first or below the last.
- [ ] Live, own playlist: drag a row a few places down, then drag one up past the top edge of
      the window so the list scrolls. Both moves stick after a reload.
- [ ] Live, queue: with a long album playing, scroll the queue away and press the toolbar's
      scroll-to-current button. The current row comes back to the centre.
