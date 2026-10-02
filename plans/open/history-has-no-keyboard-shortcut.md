# Back and forward have no keyboard shortcut

Status: **Open**, not planned
Components: `Spotifly/Views/LoggedInToolbars.swift` (`NavigationHistoryToolbarControl`),
`Spotifly/SpotiflyApp.swift` (the Navigate menu)
Found: 2026-10-02, in the review of `plans/done/now-playing-bar-missing-on-show-all-tracks.md`

## Summary

The toolbar's back and forward control is the only way through the app's history. No menu
item or shortcut reaches it: the Navigate menu has ⌘1–⌘4, Search and Refresh, and ⌘← and ⌘→
are Previous and Next track. Safari, Finder and Music use ⌘[ and ⌘].

## Solution

Not planned. Probably Back and Forward items in the Navigate menu with ⌘[ and ⌘], reaching
the coordinator the way ⌘R reaches `homeService`, as a focused scene value; see
`plans/open/menu-commands-lose-the-session-with-the-window.md` for that route's limits.

## Verification

None yet.
