# Nine keyboard shortcuts are registered twice

Status: **Done** 2026-09-29. The one question only a running app settles, Space in a text
field, measured in the test host, which builds the app's menus; the rest not yet tried in the
running app; see Verification.
Components: `Spotifly/Views/KeyboardShortcuts.swift` (now `ToolbarSearchField.swift`),
`Spotifly/SpotiflyApp.swift`, `Spotifly/Views/LoggedInContentRouterView.swift`,
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
  view modifiers that attached them, are deleted. `KeyboardShortcuts.swift` kept only
  `focusToolbarSearchField`, which the menu's ⌘F calls, and is renamed after it.
- **The menu's ⌘1–⌘4 and Refresh read the navigation as scene values.** `LoggedInView` published
  it with `.focusedValue`, which the menu sees only while a view inside it has focus; the hidden
  buttons had worked whatever had focus. With `.focusedSceneValue` the menu sees it whenever the
  window is key.

## Verification

- [x] The probe above: Space in a focused text field types a space; the menu matches Space.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live, with focus in the sidebar, then a track list, then the search field: Space plays and
      pauses (in the search field it types a space), ⌘← and ⌘→ go back and forward a track, ⌘L
      likes the current track, ⌘1 to ⌘4 open Favorites, Playlists, Albums and Artists, and ⌘F
      focuses the search field. Each does its thing once.
- [ ] Live: in search results, where the hidden buttons were never attached, the same shortcuts
      work. And in the mini player, Space plays and pauses.
