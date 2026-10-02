# A track row played only on a double-click, which accessibility cannot do

Status: **Done** 2026-10-03, verified with accessibility actions on the running app; not with
VoiceOver itself
Components: `Spotifly/Views/TrackRow.swift`
Found: 2026-10-02, with `plans/done/library-rows-not-pressable.md`

## Summary

A track row in an album, a playlist, Favorites, search or the queue starts playback on
`.onTapGesture(count: 2)`. Accessibility has no double-click, so VoiceOver could not play a track
from a list, only through the row's menu, if it reached the menu button. The row is now an
accessibility group named after its track, with Play among its actions, and the heart and the
menu are still inside it.

## Problem

The row holds its own buttons, the heart and the menu, so it cannot simply become a button the
way a library row did: a button inside a button does not work.

Without an element of its own the row was not one thing to accessibility either: its texts, its
heart and its menu sat loose among the list's other rows' texts and buttons, with nothing
saying which belonged together.

## Solution

What the double-click does moved into one method, `play()`: a track Spotify will not play says
why in the bar, and any other track calls the row's `onDoubleTap`. The double-click and a new
accessibility action both call it.

The row is `.accessibilityElement(children: .contain)`, so its texts, heart and menu stay
reachable as its children, and `.accessibilityAction(named: Text("action.play"), play)` adds Play,
the same string the library rows use. A group with no name is announced as an empty group, so it
is labelled with the track and its artist (`"Climb Up On My Music, Rodríguez"`).

## Verification

SwiftUI builds no accessibility tree in the unit test host (`NSHostingView`'s
`accessibilityChildren()` was empty), so this was checked against the running Debug build, from
outside, with the accessibility API through `osascript -l JavaScript`
(`AXUIElementCopyActionNames`, `AXUIElementPerformAction`):

- Each track row of an album, opened with `SPOTIFLY_DEBUG_OPEN`, is an `AXGroup` named
  `"<track>, <artist>"`, whose only action is `Name:Wiedergeben`.
- Its children are the now-playing glyph when it is the current track, the title, the artist
  and the duration as texts, the heart as an `AXButton` with `AXPress`, and the menu as an
  `AXMenuButton`.
- Performing the action on the first row started that track: `Playback state update:
  playing=true … uri=spotify:track:2Gu7LqbawC5nQ4pQBJHNeQ`, and Control Center's Now Playing
  named "Climb Up On My Music". It was paused straight away from the Playback menu.
- The library rows from #180 list the same action, `Name:Wiedergeben`, on their `AXButton`.

Not checked: VoiceOver itself, and a withheld track's message through the action, which goes
through the same `play()` as the double-click.

The children showed that every heart button, here and in the now-playing bar, is named by its
symbol, "Liebe" in German, whether the track is saved or not:
`plans/open/heart-buttons-are-named-love.md`.
