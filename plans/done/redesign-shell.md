# Redesign: the window's shell — accent colour and sidebar

Status: **Done**, 2026-10-21, PR #205. First of the stacked redesign PRs
Components: `Spotifly/Assets.xcassets/AccentColor.colorset`, `Spotifly/Views/SidebarView.swift`,
`Spotifly/Views/LoggedInView.swift`, the views that hard-code `.green` for the brand,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("App structure", "Sidebar",
"Design tokens")

## Summary

The handoff in `design_handoff_spotifly_macos/` redesigns the whole app in standard SwiftUI
controls. It is built as a stack of PRs, one per section of the handoff, this one first: the
pieces every later screen sits in. The accent colour becomes the brand's green, and the sidebar
takes the handoff's items and footer.

## Problem

- **Accent.** `AccentColor` is empty, so the system's blue selects sidebar rows and fills
  prominent buttons, while 20-odd places hard-code `.green` for the brand: the seek and volume
  sliders, shuffle on, the playing row, the Play button on album and playlist pages. The handoff's
  only brand value is the accent, `#1DB954`, and everything else is a system colour.
- **Sidebar.** It opens with an app-icon-and-name header the handoff does not have, calls
  Speakers "Lautsprecher" where the handoff says "Wiedergabe auf", shows no count on the queue,
  and its footer is two stacked cards (a Settings row, then a bordered profile card) where the
  handoff has one row: avatar and user name, which opens Profil, and a gear `SettingsLink`.

## Solution

### API

Nothing new. The queue badge is `PlayerModel.queueEntries.nextTracks.count` (the tracks after
the current one, which the player already reports), and the footer's avatar and name are
`AppStore.userProfile`, loaded at login.

### Accent

- `AccentColor` = `#1DB954` (sRGB 0.114, 0.725, 0.329) for light and dark.
- Brand uses of `.green` become the accent (`.tint`, `Color.accentColor`): sliders, shuffle,
  the playing row and its indicator, success ticks, the album/playlist Play buttons. Status
  colours stay system green — the connection dot is a status, not the brand, as in the
  handoff's "Verbindung" row (`#34C759`, the system green).

### Sidebar

- `List(selection:)` with no header: Startseite, Warteschlange, Wiedergabe auf; then
  `Section("Bibliothek")` with Favoriten, Playlists, Alben, Künstler. "Suchen" joins the main
  items in the search PR, which gives it a screen; until then search stays where it is.
- Warteschlange carries `.badge(n)`, the tracks still to come, and none while that is 0. The
  badge goes on the row's label, in a small view that alone reads the player: on the
  `NavigationLink` it took every row's selection highlight away (seen in the running app).
- `nav.speakers` reads "Wiedergabe auf" / "Playing On" / "Lecture sur".
- Footer, `.safeAreaInset(edge: .bottom)`: one row — a plain button with the 22 pt avatar and
  the display name, highlighted while Profil is shown, which selects Profil; then a borderless
  gear `SettingsLink`, named "Einstellungen" through the shared `.named` helper (the handoff's
  tooltip spells out "(⌘,)"; no other tooltip in the app does, so it does not either).
- The `AppBrandIcon` header goes, and with it the type if nothing else uses it.

Everything else in the shell — the player bar, the inspector, per-screen toolbars, the
three-column library — is its own PR in the stack.

## Verification

- Build, unit tests.
- Run the Debug build and screenshot the window: green selection and controls, the sidebar's
  rows and footer as in the handoff, the queue's badge counting down as tracks play, the gear
  opening Settings and the profile row opening Profil.

### Result

Built, 646 unit tests green, and checked in the running Debug build by screenshot: green
icons and selection, the queue badge (33 at the time), the footer row, the highlight following
⌘1–⌘4. `/simplify`, `/code-review` and Codex found nothing beyond the badge's view and the
string the `.named` helper replaced.
