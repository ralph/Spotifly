# Nine keyboard shortcuts are registered twice

Status: **Open.** Recorded, not planned. Needs a manual pass in the running app.
Components: `Spotifly/Views/KeyboardShortcuts.swift`, `Spotifly/SpotiflyApp.swift`
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

Not planned. Try each shortcut with focus in the sidebar, the content and the search field,
and keep one registration per shortcut. The menu commands are the likely keeper, since they
also make the shortcuts discoverable.

## Verification

Each shortcut fires once, from every focus position, with one registration left.
