# The now-playing bar's and toolbar's controls are named by their symbols, or not at all

Status: **Open**, with a proposed solution
Components: `Spotifly/Views/NowPlayingBarView.swift`, `Spotifly/Views/LoggedInToolbars.swift`,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-03, reading every control's accessibility name in the running app for
`plans/done/heart-buttons-are-named-love.md`

## Summary

Most of the bar's buttons have only an SF Symbol for a label, so accessibility names them after
the symbol. Some names happen to fit; several say something else, two controls have no name, and
the shuffle button's tooltip is English in every language.

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

Proposed:

- One shared icon button, `ToolbarActionButton`'s shape moved out of the toolbar file, which
  takes a title key and a symbol and gives both as name and tooltip. The hearts'
  `favoriteToggleName` could fold into it.
- Name each icon-only button by what pressing it does through it: Previous and Next track (the Playback
  menu's `menu.previous_track` and `menu.next_track`), Play and Pause, Shuffle on and off, the
  mini player's existing `mini_player.enter`/`restore` as its name too, Volume, and the cover as
  "Show album, artist and queue" or similar.
- The toolbar's history arrows: their tooltips (`nav.back_to …` and so on) as their names too.
- Make `shuffleHelp` localization keys, in en, de and fr.
- Give the seek bar a name ("Position") and a value read as a time (`accessibilityValue` with
  `formatTrackTime`), so VoiceOver says "1:12 of 4:54" rather than milliseconds.
- Check the mini player's own layout, which reuses some of these controls.

## Verification

Read the names, tooltips and the slider's value again with the accessibility API, in German and
in English (`-AppleLanguages '(en)'`), before and after; and check the localization tests still
find every key.
