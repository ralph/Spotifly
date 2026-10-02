# Heart buttons are named "Love", whatever they would do

Status: **Open**, with a proposed solution
Components: `Spotifly/Views/TrackRow.swift`, `Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-10-03, reading a track row's accessibility children for
`plans/done/track-rows-play-only-by-double-click.md`

## Summary

The heart in a track row and in the now-playing bar is a button whose label is only an
`Image(systemName: "heart")` or `"heart.fill"`. Accessibility names it after the symbol, "Liebe"
in German, so VoiceOver says the same thing for a saved and an unsaved track and does not say
what pressing it does. It has no tooltip either.

## Problem

Read from the running app with the accessibility API, a track row's heart is
`AXButton "Liebe"`, for a saved track as for any other. The row's menu button is named
"Weitere" by its `ellipsis` symbol, which happens to fit.

## Solution

Name both hearts by what they do, with the strings the track menu already has:
`track.menu.add_to_favorites` ("Add to Favorites") and `track.menu.remove_from_favorites`, as
`.accessibilityLabel` and `.help`, following the saved state. The image stays as it is.

## Verification

Read the hearts' `AXDescription` from the running app before and after saving a track, and
hover them for the tooltip. Saving changes the library, so a test either uses a track the user
named or reads a saved and an unsaved track as they are.
