# Artwork is drawn nine ways

Status: **Open**, not planned. A refactor; nothing is broken.
Components: `Spotifly/Views/Components/CardArtwork.swift`, `Spotifly/Views/AlbumDetailView.swift`,
`Spotifly/Views/ArtistDetailView.swift`, `Spotifly/Views/PlaylistDetailView.swift`,
`Spotifly/Views/TrackRow.swift`, `Spotifly/Views/LibraryListView.swift`,
`Spotifly/Views/NowPlayingBarView.swift`, `Spotifly/Views/SidebarView.swift`
Found: 2026-09-29, in the reuse review of `plans/done/artwork-stuck-after-network-drop.md`

## Summary

Every artwork in the app now loads through `RetryingAsyncImage`, but each of the nine sites still
writes out its own phase switch: a spinner while loading, the image resized, filled, framed and
clipped, a placeholder on failure. Five of them repeat what `CardArtwork` already does, differing
only in size, corner radius, shadow and placeholder glyph.

## Problem

- **Same switch, five times, beside `CardArtwork`:** `AlbumDetailView` (the cover),
  `PlaylistDetailView` (the cover), `ArtistDetailView` (an album card in the discography),
  `TrackRow` and `LibraryListView`. About 80 lines between them.
- **What differs:** sizes of 200, 150, 40 and 36 points against the card's fixed 120; corner radii
  of 8 and 4, and `LibrarySectionStyle.artworkShape`; shadows of 10, 2 or none; each site's
  placeholder glyph and font; and `LibraryListView` shows its placeholder, not a spinner, while it
  loads.
- **Sites that do not fit:** the artist's own image (a person glyph), the now-playing bar (it
  caches the loaded image so a track change does not flash), and the profile avatar (initials).
- **The cost of leaving it:** a change to how artwork loads or looks is nine edits, as the retry
  would have been without `RetryingAsyncImage`.

## Solution

Not planned. A likely shape: `CardArtwork` taking its size, outline and shadow as parameters, and
a placeholder, used by the five sites; the three that do not fit keep their own switch around
`RetryingAsyncImage`.

## Verification

Not planned. Every artwork looks as it did, in light and dark, loading, loaded and failed.
