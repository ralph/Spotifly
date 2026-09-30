# Artwork is drawn nine ways

Status: **Done** 2026-09-30. Built, unit tests pass, and seen in the running app in dark mode;
light mode and a failed load were not looked at (see Verification).
Components: `Spotifly/Views/Components/Artwork.swift` (was `CardArtwork.swift`),
`Spotifly/Views/Components/AlbumCard.swift`, `ArtistCard.swift`, `PlaylistCard.swift`,
`TrackCard.swift`, `Spotifly/Views/AlbumDetailView.swift`, `Spotifly/Views/ArtistDetailView.swift`,
`Spotifly/Views/PlaylistDetailView.swift`, `Spotifly/Views/TrackRow.swift`,
`Spotifly/Views/LibraryListView.swift`
Found: 2026-09-29, in the reuse review of `plans/done/artwork-stuck-after-network-drop.md`

## Summary

Every artwork in the app loads through `RetryingAsyncImage`, but each of nine sites wrote out
its own phase switch: a spinner while loading, the image resized, filled, framed and clipped, a
placeholder on failure. Seven of them now use one view, `Artwork`, which `CardArtwork` became.

## Problem

- **Same switch, five times, beside `CardArtwork`:** `AlbumDetailView` (the cover),
  `PlaylistDetailView` (the cover), `ArtistDetailView` (an album card in the discography),
  `TrackRow` and `LibraryListView`. About 80 lines between them.
- **What differed:** sizes of 200, 150, 40 and 36 points against the card's fixed 120; corner
  radii of 8 and 4, and `LibrarySectionStyle.artworkShape`; shadows of 10, 2 or none; each site's
  placeholder glyph and font; and `LibraryListView` shows its placeholder, not a spinner, while it
  loads.
- **Sites that do not fit:** the artist's own image (a person glyph, drawn without a fill), the
  now-playing bar (it caches the loaded image so a track change does not flash), and the profile
  avatar (initials).
- **The cost of leaving it:** a change to how artwork loads or looks was nine edits.

## Solution

- **`Artwork`** takes the images, its size, its shape, the placeholder's glyph and font, an
  optional shadow, and whether to show the placeholder instead of a spinner while loading. The
  shadow is optional rather than zero, since a zero-radius shadow still costs a render pass in
  every track row.
- **`Artwork.card(_:shape:symbol:symbolSize:)`** is what `CardArtwork` was: 120 points, a
  rounded square or a circle, a shadow of 2. `Artwork.cardSize` replaces `CardArtwork.size`
  for the captions.
- **`Artwork.header(_:shape:symbol:symbolSize:)`** is the 200-point artwork at the top of an
  album's, an artist's and a playlist's page, with a shadow of 10.
- **The discography, `TrackRow` and `LibraryListView`** pass what they differ in. `TrackRow`
  still leaves the column out for a track with no images at all, as it did, and hands every row
  one shape made once.
- **The artist's own image** fits after all, as a header with a circle: its placeholder was the
  one difference, and it now matches the artist cards'.
- **One look for the placeholder:** a secondary glyph on a quaternary fill of the artwork's
  shape. The visible changes:
  - the album and playlist headers, a track row's failed artwork and the now-playing bar drew
    their glyph in the primary colour; the bar keeps its own view but now draws it secondary;
  - the artist header's placeholder was a large tertiary person glyph with no fill.
- **Left out:** the now-playing bar, which keeps its loaded image in state, and the profile
  avatar, which falls back to initials. Each keeps its own switch around `RetryingAsyncImage`.

### Not done

- `ArtistDetailView` keeps a private `AlbumCard` for the discography, 150 points with the
  release year, beside `Components/AlbumCard`. One card with a caption option would remove it
  and its set of artwork values. A design question more than a duplicate.
- Whether the now-playing bar's cached image still earns its keep. It came with a change about
  resizing the bar, and the bar has one call site now; if not, the bar fits `Artwork` too.

## Verification

- [x] Build, 464 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] In the running app, dark mode, 2026-09-30:
  - the start page's cards, square and round, with their shadow;
  - the Albums and Artists lists (36 points, rounded and round);
  - an album's header (200 points, radius 8, shadow);
  - an artist's header (200 points, a circle, shadow);
  - an artist's discography (150 points, radius 8, no shadow);
  - a playlist's track rows (40 points, radius 4);
  - the placeholder, in the header and the list row of a playlist without a cover: a secondary
    glyph on a quaternary rounded square.
- [x] Rebuilt after the review, 2026-09-30: an artist's header as a circle with its shadow, and the
      now-playing bar's placeholder glyph in grey.
- [ ] Light mode. Not switched: the colours are the semantic `.secondary` and `.quaternary`, as
      before.
- [ ] A failed load. Not induced; it shows the same placeholder as no artwork, seen above.
