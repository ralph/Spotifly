# Back and forward had no keyboard shortcut

Status: **Done** 2026-10-02, verified live through the menu; the key equivalents themselves were
not typed
Components: `Spotifly/SpotiflyApp.swift` (the Navigate menu, the focused values),
`Spotifly/Views/LoggedInView.swift`
Found: 2026-10-02, in the review of `plans/done/now-playing-bar-missing-on-show-all-tracks.md`

## Summary

The toolbar's back and forward control was the only way through the app's history. The Navigate
menu now has Back (⌘[) and Forward (⌘]), as Safari, Finder and Music do; ⌘← and ⌘→ were already
Previous and Next track.

## Solution

- **The window publishes its `NavigationCoordinator`** as a focused scene value, which the menu
  calls `navigateBackward()` and `navigateForward()` on. ⌘1–⌘4 now call `selectNavigationItem`
  on it too, where they set a focused binding of the sidebar's selection; the sidebar binds the
  coordinator's selection directly.
- **Back and Forward are a small view inside the menu**, `NavigationHistoryMenuItems`, disabled
  by the coordinator's `canNavigateBackward` and `canNavigateForward`. A view's body follows the
  coordinator as it moves, where the menu's own body is drawn again only when a focused value
  changes, and the coordinator stays the same object. A first version carried the two flags as
  a second focused value; the review found this simpler form, which was then checked the same
  way.
- The titles are the toolbar's own, `nav.back` and `nav.forward`: Zurück and Vorwärts, Retour
  and Suivant.

Like ⌘1–⌘4 and ⌘R, they act on the key window, and are disabled without one.

## Verification

### Live (2026-10-02)

Through `app_menu`, Spotifly frontmost:
- At launch, Back was disabled: no history.
- Navigation → Alben, then Zurück: the start page. Then Vorwärts: Albums again, its first album
  selected.
- Then Vorwärts once more: refused as disabled, with nothing ahead.

The first tries found Back disabled after two steps. Those menu presses followed each other with
no pause; with a few seconds between them, the items had caught up. Not checked: the key equivalents
typed on a keyboard, since that needs control of the screen. A German layout has no `[` key of
its own; macOS's automatic localization of key equivalents decides what it becomes there.

### Unit tests

611 pass; the coordinator's history is unchanged and covered by `NavigationCoordinatorTests`.
