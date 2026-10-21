# Redesign: Einstellungen

Status: **Done**, 2026-10-21, PR #218. Fourteenth and last of the stacked redesign PRs
Components: `Spotifly/Views/PreferencesView.swift`, `Spotifly/SpotifyPlayer.swift`,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Settings window")

## Summary

The settings window becomes the handoff's: 600 pt wide, tabs Allgemein, Wiedergabe and
Kurzbefehle, and a version line at the foot of each. Only what the app can do is offered.

## Problem

The window is 450 pt wide with the tabs General (appearance as a menu), Playback (quality as a
menu with English names such as "Normal (160 kbps)", gapless) and Info (icon, version,
copyright, GitHub).

## Solution

### What the handoff asks for and the app has not got

Left out, each because nothing in the app would act on it:

- **Allgemein**: "Beim Start öffnen" (the app opens where it was), "Im Dock anzeigen" (no menu
  bar presence to fall back on), "Mitteilung bei Titelwechsel" (no notifications), and the
  whole "Offline-Cache" section (no cache: nothing in `SwiftLibrespot` keeps audio on disk).
- **Wiedergabe**: "Lautstärke angleichen" (the port does not normalise) and "Autoplay" (no
  setting for it; Spotify's own decides).
- **Footer**: "Librespot 0.6.0": the player is a Swift port of librespot, with no version of
  its own to report.

### Window

- 600 pt wide; `TabView` with Allgemein, Wiedergabe, Kurzbefehle, each a grouped `Form`.
- Allgemein: Erscheinungsbild as a segmented picker, System / Hell / Dunkel.
- Wiedergabe: Streaming-Qualität 96 / 160 / 320 kbit/s (no "Auto"), Lückenlose Wiedergabe, and
  under them the note that a change applies when playback restarts. `Bitrate`'s English
  display names go: the picker shows the rate.
- Kurzbefehle: a read-only list, `LabeledContent` per shortcut, named as its menu item names
  it, from one table (`AppShortcut`) the menus bind too: Abspielen / Pause (Leertaste), next and previous (⌘→ / ⌘←), Lauter / Leiser (⌘↑ / ⌘↓),
  Track liken (⌘L), Suchen (⌘F), Seitenleiste (⌃⌘S), Jetzt läuft (⌥⌘I), Mini-Player (⌥⌘M),
  Zurück / Vorwärts (⌘[ / ⌘]), Favoriten … Künstler (⌘1–⌘4), Aktualisieren (⌘R),
  Einstellungen (⌘,).
- Foot of the window: "Spotifly 1.x (build)" and the GitHub link, which replaces the Info tab.

## Verification

- Build, unit tests.
- Run the Debug build: open the window (⌘,), each tab; switch the appearance and back; change
  the quality and back.

### Result

- Live: the window at 600 pt, each tab its own height (Allgemein a single row, Wiedergabe two
  and the note, Kurzbefehle scrolling), the version and GitHub link at each foot; Hell restyled
  the window and was set back to System; the quality, 320 kbit/s, was left as it was.
- `/simplify`: the shortcut list was a hand-kept copy of the menus' bindings; `AppShortcut` is
  now the one table both read. The playback tab no longer writes a change twice or re-applies
  both settings when it appears; the version comes from `DeviceInfo.appVersion`.
- Kept: the fixed tab heights, as a grouped form sizes to no content of its own, and the
  footer under each tab, since under the `TabView` the window took the tallest tab's height.
  `/code-review` raised both, and the system-bound rows (⌃⌘S, ⌘,) the table only lists; Codex
  found nothing.
