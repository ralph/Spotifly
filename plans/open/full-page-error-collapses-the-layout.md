# A page that failed to load squeezes the window

Status: **Open**, not planned. Seen 2026-09-29 while testing #82. The cause below is read from
the code and the screen, not yet confirmed by a change.
Components: `Spotifly/Views/AlbumDetailView.swift`, `Spotifly/Views/ArtistDetailView.swift`,
`Spotifly/Views/PlaylistDetailView.swift` (their full-page error branch),
`Spotifly/Views/Components/InlineLoadError.swift`, `Spotifly/Views/LoggedInView.swift`
(`contentRegion`)
Found: 2026-09-29, testing #82 with `SPOTIFLY_DEBUG_OPEN`, on a German account

## Summary

When a detail page's first load fails, its error message is laid out at its own small height,
and the whole split view shrinks to it. The library list beside it is cut to a single row, the
message and that row sit in the middle of the window, and the now-playing bar floats in the
middle of the window instead of at its bottom. Nothing is lost, and the page recovers once
another section is chosen, but it looks broken.

## Problem

### What was seen

- **Album.** `SPOTIFLY_DEBUG_OPEN=spotify:album:2ZWlPOoWh0626oTaHrnl2a` (Discovery's US id)
  opens the Albums section on an album Spotify cannot find. The message, "Album wurde nicht
  gefunden. Vielleicht ist es in deinem Land nicht verfügbar.", was right, with no Try again.
  But around it:
  - The album list showed one row, "Alive", at the window's vertical middle, where it
    normally fills the column from the top.
  - The message sat at the same height, in red, partly under the bar.
  - The now-playing bar sat across the middle of the window, not at the bottom.
  - The window above and below that band was empty.
- **Artist.** `SPOTIFLY_DEBUG_OPEN=spotify:artist:0000000000000000000000` did the same, with
  "Künstler wurde nicht gefunden."
- **Why it was not seen before #82.** Until #82, a failed first load looped: its `.task` sat on
  a `Group`, so the error branch started the load again. The page showed the spinner nearly
  all the time, and the spinner fills its space. #82 stopped the loop, so the error now stays
  on screen, and so does its layout.

### Why, as read from the code

- **The branches size differently.** The three detail views switch between three branches at
  their root, a `ZStack` since #82:
  - the content, which is a `ScrollView` and fills;
  - `ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)`, which fills;
  - `InlineLoadError(…)`, a padded `VStack` of a text and maybe a button, with **no flexible
    frame**. Its ideal height is a few dozen points.
- **The split view follows it.** In the Albums, Artists and Playlists sections,
  `LoggedInView.contentRegion` is an `HSplitView` of the list (`contentRouter`) and the detail
  (`LoggedInDetailRouterView`, `.frame(maxWidth: .infinity)`, width only). With the detail
  column rigid in height, the split view seems to take that height. It is then centred in the
  window, and the list column shrinks to it. That this is how `HSplitView` sizes is the
  reading of the screen; it is not confirmed.
- **The bar follows the split view.** `NowPlayingBarView` is an
  `.overlay(alignment: .bottom)` on `contentRegion`, so it sits at the bottom of whatever
  height the split view took, which is now the middle of the window.

### Where else it applies

- **Every full-page error in these three views:** a network error on an album, artist or
  playlist opened for the first time (#82's check 4 will show it), a playlist Spotify cannot
  find (#85), and any other first-load failure.
- **Not the section errors.** The same `InlineLoadError` used for a track list or a
  discography, inside a page whose header loaded, sits inside a `ScrollView` and is fine.
- **Possibly `LibraryListView`.** Its own loading, error and empty states are `VStack`s
  without a flexible frame, in the list column. Not seen, but the same shape.

## Solution

Not planned. The likely change: give the full-page error branch the spinner's
`.frame(maxWidth: .infinity, maxHeight: .infinity)` at the three call sites
(`AlbumDetailView`, `ArtistDetailView`, `PlaylistDetailView`). Or have `InlineLoadError` fill
when it stands for the whole page, for example with a flag or a second initializer, so the
section uses keep their size. Check `LibraryListView`'s states while there.

A deeper option is to pin the now-playing bar to the window, or to the split view's full
height, rather than to whatever height the content takes. Then no content state can move it.

## Verification

Not planned. To reproduce, on a German account (the `SPOTIFLY_DEBUG_OPEN` hook came with #82):

```bash
SPOTIFLY_DEBUG_OPEN=spotify:album:2ZWlPOoWh0626oTaHrnl2a "$(xcodebuild -scheme Spotifly -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Spotifly.app/Contents/MacOS/Spotifly"
```

Or turn Wi-Fi off and open an album that has not been opened before. After the fix:
- the list column still fills from the top;
- the message is centred in the detail column;
- the bar is at the bottom of the window.
