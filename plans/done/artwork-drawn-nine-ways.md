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
placeholder on failure. Six of them now use one view, `Artwork`, which `CardArtwork` became.

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
- **The five sites** pass what they differ in. `TrackRow` still leaves the column out for a
  track with no images at all, as it did.
- **One look for the placeholder:** a secondary glyph on a quaternary fill of the artwork's
  shape. The album and playlist headers and a track row's failed artwork drew their glyph in the
  primary colour, which the cards, the discography and the library lists did not. This is the
  one visible change.
- The three that do not fit keep their own switch around `RetryingAsyncImage`.

## Verification

- [x] Build, 464 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] In the running app, dark mode, 2026-09-30:
  - the start page's cards, square and round, with their shadow;
  - the Albums and Artists lists (36 points, rounded and round);
  - an album's header (200 points, radius 8, shadow);
  - an artist's discography (150 points, radius 8, no shadow);
  - a playlist's track rows (40 points, radius 4);
  - the placeholder, in the header and the list row of a playlist without a cover: a secondary
    glyph on a quaternary rounded square.
- [ ] Light mode. Not switched: the colours are the semantic `.secondary` and `.quaternary`, as
      before.
- [ ] A failed load. Not induced; it shows the same placeholder as no artwork, seen above.
