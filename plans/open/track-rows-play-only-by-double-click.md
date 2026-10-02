# A track row plays only on a double-click, which accessibility cannot do

Status: **Open**
Components: `Spotifly/Views/TrackRow.swift`
Found: 2026-10-02, with `plans/done/library-rows-not-pressable.md`

## Summary

A track row in an album, a playlist, Favorites, search or the queue starts playback on
`.onTapGesture(count: 2)`. Accessibility has no double-click, so VoiceOver cannot play a track
from a list, only through the row's menu, if it reaches the menu button.

## Problem

The row holds its own buttons, the heart and the menu, so it cannot simply become a button the
way a library row did: a button inside a button does not work. It needs an accessibility action,
probably named Play, on the row as a group, with the heart and the menu still reachable.

## Solution

None yet. Checking it needs VoiceOver, or another way to see a group's custom actions.

## Verification

None yet.
