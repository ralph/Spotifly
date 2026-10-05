# Nine keyboard shortcuts are registered twice

Status: **Done** 2026-09-29 (#102). Space in a text field measured in the test host, which builds
the app's menus; the shortcuts tried in the running app on 2026-09-30, all but the login screen; see
Verification.
Components: `Spotifly/Views/KeyboardShortcuts.swift` (deleted), `Spotifly/SpotiflyApp.swift`, `Spotifly/Views/LoggedInContentRouterView.swift`,
`Spotifly/Views/LoggedInView.swift`
Found: 2026-08-15, in a review of the plans. Re-checked 2026-09-29.

## Summary

Nine shortcuts exist twice, once as a hidden button and once as a menu command, with the same
action. Which copy fires depends on focus.

## Problem

Space, ⌘←, ⌘→, ⌘L, ⌘1–4 and ⌘F are registered as hidden zero-size buttons in
`Views/KeyboardShortcuts.swift` and as menu commands in `SpotiflyApp.swift`. Which copy wins
depends on focus semantics, such as Space in the search field versus Space as a menu key
equivalent. Only a running app settles that; reading the code cannot.

## Solution

The menu commands stay, as the plan expected: they also make the shortcuts discoverable. The
hidden buttons are gone.

### What decides it

Both copies call the same action, and AppKit stops at the first key equivalent that takes an
event, so neither shortcut fired twice. What removing one copy could change is which keys reach
a text field. Space is the one without a modifier: if the menu's plain-Space Play/Pause took
keystrokes from text fields, and it had been the hidden button that answered Space there,
removing the button would have made typing a space in Search toggle playback.

Measured with a probe test in the test host, which runs `SpotiflyCommands` and so has the real
menu, Play/Pause on Space included: a window with a focused `NSTextField`, sent `a`, Space and
`b` through `NSApp.sendEvent`, typed `a b`. Asked directly, the same menu does take Space
(`performKeyEquivalent` answered true). So the menu's Space plays and pauses everywhere except in
a text field, which gets its space, and it can be the one registration.

### What changed

- `PlaybackShortcutsView`, `LibraryNavigationShortcutsView` and `SearchShortcutsView`, and the
  view modifiers that attached them, are deleted, and with them `KeyboardShortcuts.swift`.
  `focusToolbarSearchField`, which the menu's ⌘F calls, moved into `SpotiflyApp.swift`, its
  only caller.
- **The menu's ⌘1–⌘4 and Refresh read the navigation as scene values.** `LoggedInView` published
  it with `.focusedValue`, which the menu sees only while a view inside it has focus; the hidden
  buttons had worked whatever had focus. With `.focusedSceneValue` the menu sees it whenever the
  window is key.
- **Those items are greyed where there is nothing to act on**, as at the login screen or with
  Settings key, instead of enabled and doing nothing (from the review).

## Verification

- [x] The probe above: Space in a focused text field types a space; the menu matches Space.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] Live, 2026-09-30: Space plays and pauses with focus in the sidebar and in a track list, and in
      the search field types a space and leaves playback alone. From the sidebar and from the search
      field, ⌘→ and ⌘← go forward and back one track, ⌘L likes and unlikes the current track, ⌘1 to
      ⌘4 open Favorites, Playlists, Albums and Artists, and ⌘F focuses the search field. Each did
      its thing once.
- [x] Live, 2026-09-30: with search results showing, ⌘→, ⌘←, ⌘2 and ⌘3 work. Focus stays in the
      search field there, so Space types. In the mini player, Space plays and pauses.
      Later (2026-10-03): it stayed there whatever was clicked next, so Space never played or
      paused again until the field lost focus; a click elsewhere now ends its editing.
- [ ] Live: at the login screen, the Navigate menu's Favorites to Artists and Refresh are greyed.
      Not run: it needs signing out.
