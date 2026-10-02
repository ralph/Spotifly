# Heart buttons were named "Love", whatever they would do

Status: **Done** 2026-10-03, verified with the accessibility API on the running app; the
tooltips on hover not seen
Components: `Spotifly/Views/TrackRow.swift`, `Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-10-03, reading a track row's accessibility children for
`plans/done/track-rows-play-only-by-double-click.md`

## Summary

The heart in a track row and in the now-playing bar is a button whose label is only an
`Image(systemName: "heart")` or `"heart.fill"`. Accessibility named it after the symbol, "Liebe"
in German, so VoiceOver said the same thing for a saved and an unsaved track and did not say
what pressing it does. It had no tooltip either. Both hearts are now named by what they do, as
their accessibility label and their tooltip.

## Problem

Read from the running app with the accessibility API, a track row's heart was
`AXButton "Liebe"`, for a saved track as for any other. The row's menu button is named
"Weitere" by its `ellipsis` symbol, which happens to fit.

### A row's tooltip stood in for its heart's

The first fix gave both hearts a tooltip, and only the bar's heart showed it (`AXHelp`). A track
row sets `.help(track.unplayableMessage ?? "")` on the whole row, and an outer `.help` wins over
an inner one: every row heart's help came out empty. For a withheld track that precedence is
what the row wants, its reason on every part of it; for any other track it only blanked its
heart's.

## Solution

- `View.favoriteToggleName(isFavorited:)`, beside `TrackRow`, gives a heart the track menu's own
  strings, `track.menu.add_to_favorites` ("Add to Favorites") or
  `track.menu.remove_from_favorites`, as `.help` and `.accessibilityLabel`, following the saved
  state. Both hearts use it. The image is unchanged.
- The track menu's Add/Remove item takes its title from the same place,
  `LocalizedStringKey.favoriteToggle(isFavorited:)`.
- The row's tooltip is set only where there is a message, through `View.help(ifAny:)`, so a
  playable track's row no longer covers its heart's with an empty one. A search card's tooltip
  uses it too, for one idiom, though nothing inside a card has a tooltip of its own.

## Verification

With `osascript -l JavaScript` against the running Debug build (`AXDescription`, `AXHelp`):

- An album of unsaved tracks: every row heart, and the bar's, read
  `"Zu Favoriten hinzufügen"` as name and help. Before, `"Liebe"`, with no help.
- Favorites: the 27 rows built read `"Aus Favoriten entfernen"` as name and help.
- The withheld "Girlfriend (feat. Dâm-Funk)" in Favorites, scrolled to with `AXScrollToVisible`:
  its texts, heart and menu all have the help
  `In deinem Land nicht verfügbar: „Girlfriend (feat. Dâm-Funk)“`, as before, and its heart is
  still named `"Aus Favoriten entfernen"`.
- Nothing was saved or removed.

Not seen: the tooltips on hover, which needs the pointer over the window, and VoiceOver itself.

Reading every control's name for this turned up the rest of the bar and the toolbar's arrows,
named by their symbols or not at all: `plans/open/now-playing-bar-controls-named-by-their-symbols.md`.
