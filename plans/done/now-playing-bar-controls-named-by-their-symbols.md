# The now-playing bar's and toolbar's controls were named by their symbols, or not at all

Status: **Done** 2026-10-03, verified with the accessibility API on the running app, in German
and English; the tooltips on hover and VoiceOver itself not seen
Components: `Spotifly/Views/Components/ControlName.swift` (new), `Spotifly/Views/NowPlayingBarView.swift`,
`Spotifly/Views/LoggedInToolbars.swift`, `Spotifly/Views/TrackRow.swift`,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-03, reading every control's accessibility name in the running app for
`plans/done/heart-buttons-are-named-love.md`

## Summary

Most of the bar's buttons had only an SF Symbol for a label, so accessibility named them after
the symbol. Some names happened to fit; several said something else, two controls had no name, and
the shuffle button's tooltip was English in every language. Every icon-only control in the bar
and the toolbar is now named by what it does, as its tooltip and to accessibility, through one
modifier, and the two sliders read as a time and a percentage.

## Problem

Read from the running Debug build in German, with the accessibility API (`AXDescription`,
`AXHelp`, `AXIdentifier`):

| Control | Name | Tooltip |
|---|---|---|
| Cover art, which opens Go to Artist, Go to Album and Queue | none | none |
| Shuffle (`shuffle`) | "Zufällig" | "Enable shuffle", in English |
| Previous track (`backward.fill`) | "Zurück", as the toolbar's history arrow | none |
| Play/Pause (`play.fill`) | "Wiedergeben" | none |
| Next track (`forward.fill`) | "Weiter", as the toolbar's forward arrow | none |
| Mini player (`arrow.down.right.and.arrow.up.left`) | "Vollbildmodus Aus" ("full screen off") | "Mini-Player-Modus aktivieren" |
| Volume, which opens a slider (`speaker.wave.3.fill`) | "Lauter" ("louder") | none |
| Seek bar | none, its value the position in milliseconds ("12673") | none |
| Toolbar, Back (`chevron.left`) | "Zurück" | "Zurück" |
| Toolbar, Forward (`chevron.right`) | "Weiter" | "Vorwärts" |

The heart and the queue button are named by what they do (`favoriteToggleName`, and
`queue.open`), as is the cover's popover's content. So are the context toolbar's actions, through
`ToolbarActionButton` in `LoggedInToolbars.swift`: a `Label(title, systemImage:)` with
`.labelStyle(.iconOnly)` and `.help(title)`, one key for the name and the tooltip. A tooltip alone
does not name a button: `.help` fills `AXHelp` only, as the history arrows show.

`shuffleHelp` returns three English `String`s, which `.help(String)` shows verbatim, so they were
never looked up as localization keys.

## Solution

- `View.named(_:)`, in `Views/Components/ControlName.swift`, sets one key as a control's tooltip
  and its accessibility label; `named(verbatim:)` takes a string already looked up. The hearts'
  `favoriteToggleName` became `.named(.favoriteToggle(isFavorited:))`, and the queue button's
  `.help` and `.accessibilityLabel` pair became `.named("queue.open")`.
- The bar: Previous and Next take the Playback menu's `menu.previous_track` and
  `menu.next_track`; Play/Pause `action.play` or a new `action.pause`; the cover
  `now_playing.cover_menu` ("Go to Artist, Album or Queue"); the mini player its existing
  `mini_player.enter`/`restore` as its name too; the volume button `volume.title`.
- Shuffle is named `shuffle.enable` or `shuffle.disable`, and its tooltip says
  `shuffle.unavailable` while greyed out. The three English `String`s it had are gone.
- The seek bar is named `now_playing.position`, with `now_playing.position_value %@ %@`
  ("0:12 of 4:54") as its value, which was milliseconds. The volume slider is named
  `volume.title`, with its value as a percentage, which was a fraction of a hundred
  (`60.59375`).
- The toolbar: the history arrows' tooltips (`nav.back_to …`) are their names too, and refresh
  and scroll-to-current are named by their keys.
- The context toolbar's actions were already named, through `ToolbarActionButton`'s
  `Label`, and are unchanged. The mini player uses the same layout as the bar.

## Verification

With `osascript -l JavaScript` against the running Debug build (`AXDescription`, `AXHelp`,
`AXValueDescription`), Favorites open:

- **German:** "Zufallswiedergabe einschalten", "Vorheriger Track", "Wiedergeben",
  "Nächster Track", "Zu Künstler, Album oder Warteschlange", "Zu Favoriten hinzufügen",
  "Warteschlange öffnen", "Mini-Player-Modus aktivieren", "Lautstärke", each the same as its
  help; the slider "Position" with the value "0:12 von 4:54"; the toolbar's "Zurück zu
  Startseite", "Vorwärts", "Aktualisieren".
- **English** (`-AppleLanguages '(en)'`): "Enable shuffle", "Previous Track", "Play",
  "Next Track", "Go to Artist, Album or Queue", "Add to Favorites", "Open queue",
  "Enter mini player mode", "Volume"; "0:12 of 4:54"; "Back to Startpage", "Forward",
  "Refresh". The volume popover, opened by pressing "Volume", has a slider named "Volume" with
  the value "61 %".
- Pressing the mini player button renamed it "Restore full window", and pressing that, back.
- With the silent librespot device playing and Spotifly following it, the play button read
  "Pause".
- The localization tests pass with the new keys in en, de and fr.

Not seen: the shuffle tooltip while greyed out, which needs a radio playing; the tooltips on
hover; VoiceOver itself.
