# The end of a list sits under the now-playing bar

Status: **Done** (2026-10-01). Seen by hand on 2026-10-01, testing `plans/done/list-failures-the-retry-cannot-see.md`.
Components: `Spotifly/Views/LoggedInView.swift` (the bar's overlay, and now the room for it),
`Spotifly/Views/NowPlayingBarView.swift` (`contentClearance`), `Spotifly/Views/SpeakersView.swift`,
and the five views that each left room themselves
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

- **And the profile**, found on the way: `UserProfileView` scrolls and left no room either.
- **Speakers was a sixth site**, as a `.safeAreaInset` of 80.

## Solution

The room is given once, where the bar is laid over the content: `LoggedInView.contentRegion`
sets `.contentMargins(.bottom, NowPlayingBarView.contentClearance)` just before its
`.overlay(alignment: .bottom)`. The bar's view names the clearance, 100 as before: its height,
the 20 points under it, and 20 to spare. The five views that left room themselves no longer do.

Measured in throwaway layout probes in the test host, reading each `NSScrollView`'s
`contentInsets`, before choosing this over one modifier per view:

- **A margin set on a container reaches the outermost scroll view inside it, and not the scroll
  views nested in that one.** A vertical `ScrollView` under the margin had a bottom inset of 100,
  and a horizontal `ScrollView` inside it, like the start page's and search's shelves, had 0 and
  kept its height of 80. So the shelves are not padded.
- **It passes through `HSplitView`**: both panes of the three-column layout had 100.
- **A `List` ignores it on macOS** (inset 0, document height unchanged), and takes a
  `.safeAreaInset` instead (80 for 80). So Speakers, the one `List` in the content, keeps its
  inset, sized by the same constant.
- **The safe area does not pass through `HSplitView`.** That ruled out the other general form,
  placing the bar with `.safeAreaInset` instead of an overlay: the three-column panes got 0.

The default placement is used rather than `.scrollContent`, so the scroll indicator stops above
the bar too, as the queue's and start page's already did.

## Verification

- Unit tests and the lint pass.
- The probes above, for each mechanism.
- By hand: scroll each list to its end with the bar showing a track: Favorites, Playlists,
  Albums, Artists, search results and search's all tracks, the profile, Speakers, the queue, the
  start page and an album, artist and playlist page. The last row is above the bar and can be
  clicked. Offline, the end of Favorites with its Try again is above the bar. The shelves on
  the start page and in search are no taller than before.
