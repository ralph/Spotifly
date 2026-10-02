# Library rows could not be pressed by accessibility

Status: **Done** 2026-10-02, verified with accessibility presses; not with VoiceOver itself
Components: `Spotifly/Views/LibraryListView.swift` (`LibraryRow`), `Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-02, in the review of the playlist folders' update (#104), whose folder rows had the
same gap

## Summary

A row of the Playlists, Albums and Artists sections was selected by a tap gesture, which
accessibility cannot press: VoiceOver could not open a playlist, album or artist from the list,
and its play button shows only under the pointer. The row is now a button, says when it is
selected, and has Play as an action.

## Problem

`LibraryRow` drew its content with `.onTapGesture(perform: onSelect)`. A tap gesture gives the
element no press: accessibility saw the row's text and image, not something to press, so a
VoiceOver user, or anything else that drives the app through accessibility, could not select an
entry. The play button is an overlay shown while the pointer is over the row, so it was out of
reach too.

## Solution

- **The row is a `Button`** with the plain style, whose action selects, so a click works as
  before and a press selects.
- **Selected** is reported (`.isSelected`), as the highlight shows it.
- **Play is a named action** of the row (`action.play`: Play, Wiedergeben, Lire), the same call
  as the hover button, which stays where it was: an overlay outside the row's button, so the two
  do not nest.

Left for its own plan: a track row's double-click, `plans/open/track-rows-play-only-by-double-click.md`.

## Verification

### Live (2026-10-02)

Albums listed each row to accessibility as a button named by its album ("Saviors (édition de
luxe)", "Cold Fact"), where it had been text. An accessibility press on "Cold Fact" selected it
and opened its page. Not checked: VoiceOver itself, and its actions menu for Play, which needs
someone at the keyboard.

### Unit tests

611 pass, with `LocalizationTests` covering the new string in every language.
