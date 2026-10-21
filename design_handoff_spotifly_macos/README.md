# Handoff: Spotifly — native macOS client (SwiftUI)

## Overview
A native macOS Spotify client ("Spotifly") built on the Spotify Web API for metadata/control and Librespot for audio. The design uses standard SwiftUI controls throughout. The one exception is the floating player bar, which is a custom layout assembled from standard Buttons and Sliders. The UI language is German.

## About the design files
The files in `design/` are **design references built in HTML/React**: prototypes that show the intended look and behavior. They are not production code. Rebuild them in **SwiftUI (macOS 26, Liquid Glass)** with native controls. Don't port the CSS. Wherever the CSS imitates a system control, use the real control, and let it render natively.

To view: open `design/Spotifly Native.html` in a browser. In the Tweaks panel, turn on **"SwiftUI-Controls markieren"**. Each element then gets an outline, and hovering shows the SwiftUI control it maps to (from the `data-sw` attributes in the source). Orange outlines mark custom views.

## Fidelity
**High fidelity** for layout, hierarchy, copy, control choice and behavior. Visual details like control chrome, materials, fonts and selection colors come from the system: use the system defaults and don't copy the CSS values. The only brand value is the accent color.

## App structure
- `WindowGroup` → `NavigationSplitView` with a sidebar (`List(.sidebar)`) and a detail area. Library screens use a **three-column** split view.
- Bottom: player bar via `.safeAreaInset(edge: .bottom)` + `.glassEffect()`. It floats and is centered, `width = min(780, container − 40)`, 64pt high, with a capsule shape.
- Right: "Jetzt läuft" as a `.inspector(isPresented:)`, 320pt wide.
- `Settings { TabView }` scene (⌘,). Settings are a separate window, **not** a sidebar entry.
- Toolbar per screen: back/forward `ControlGroup`, `.navigationTitle`, and screen-specific `ToolbarItem`s.

### Sidebar
Main items: Startseite, Suchen, Warteschlange (`.badge` = remaining tracks in the queue), Wiedergabe auf. `Section("Bibliothek")`: Favoriten, Playlists, Alben, Künstler. Footer (`.safeAreaInset(.bottom)`): avatar + username → Profil, and a `SettingsLink` gear button.

## Screens
**Startseite**: Toolbar: Refresh (⌘R). Sections:
1. "Zuletzt gehört": horizontal `ScrollView` + `LazyHStack` of album cards, 150pt wide (`/me/player/recently-played`).
2. "Deine Top-Titel": `LazyVGrid` (adaptive, min 260pt), with a segmented `Picker` in the header: 4 Wochen / 6 Monate / 1 Jahr (`/me/top/tracks?time_range=short|medium|long_term`).
3. "Deine Top-Künstler": horizontal row of round artist cards, 130pt wide.
4. "Deine Playlists": horizontal row, with a `.link` button "Alle anzeigen" that opens Playlists.

**Suchen**: `.searchable(placement: .toolbar)`, placeholder "Songs, Künstler, Alben, Podcasts", focused automatically.
- Empty query: Form section "Letzte Suchen" (footer: "Wird nur auf diesem Mac gespeichert."), each row has a remove button, plus a "Verlauf löschen" button. With no history, show a `ContentUnavailableView`.
- With a query: segmented scope Alle / Songs / Künstler / Alben / Playlists / Podcasts. Results show at most **10 per type** (API limit). When a single scope is selected, a "Mehr laden" button pages via `offset`. No results: `ContentUnavailableView("Keine Ergebnisse für „…“")`.

**Warteschlange**: Toolbar: Refresh, "Alle in den Offline-Cache laden". A track table with a "C" tag on tracks in the offline cache. The queue is **read-only plus append**: no reordering, removing or clearing (API limit).

**Wiedergabe auf**: grouped Form.
- Section "Spotify Connect": list of devices; selecting one transfers playback.
- Section "AirPlay": `AVRoutePickerView` via `NSViewRepresentable`.
- Section "Verbindung": status (green dot, "Verbunden seit …") and a `DisclosureGroup` with details.

**Favoriten**: Detail header (132pt art, kind label, title, "N Titel · Dauer", `.borderedProminent` "Abspielen" + `.bordered` "Zufällig"). Below it, a `Table` with `sortOrder` and columns #, Titel, Album, Hinzugefügt (`added_at`), Dauer, plus an actions column (heart + menu that appears on hover). `.searchable` in the toolbar.

**Playlists / Alben / Künstler**: three-column split view.
- Content column: `List(selection:)` with its own search field, width clamp(200, 28%, 300).
- Detail column: the same detail header. Below 520pt width, the header stacks vertically.
- Playlists: toolbar has New playlist, `ShareLink`, and a `Menu`. Own playlists show a sortable `Table`. **Other people's playlists** show `ContentUnavailableView("Titelliste nicht verfügbar", lock)` with the text "Spotify gibt die Titel nur für eigene oder gemeinsame Playlists frei. Abspielen funktioniert trotzdem." and an "In Spotify öffnen" button. Play still works. A Follow toggle button ("In Bibliothek"/"Zur Bibliothek") also appears.
- Alben: toolbar sort `Picker(.menu)`. Header shows "Album · Jahr", an artist link, the track count and the duration, plus a Save toggle.
- Künstler: Follow toggle. "Diskografie" uses a segmented picker Alben / Singles & EPs / Compilations (`include_groups`) and a `LazyVGrid` (min 150pt). **No** top tracks, monthly listeners or followers.

**Profil**: Centered avatar and name. Form section "Konto": Anzeigename, Benutzer-ID (selectable text + copy button), "Profil im Web" `Link`. No stats, plan or country.

**Settings window** (600pt wide, toolbar tabs):
- Allgemein: Beim Start öffnen (`Picker .menu`), Erscheinungsbild (segmented System/Hell/Dunkel), Im Dock anzeigen, Mitteilung bei Titelwechsel. Section Offline-Cache: Maximale Größe (1/5/10 GB/Unbegrenzt), Belegt + "Leeren …".
- Wiedergabe: Streaming-Qualität 96/160/320 kbit/s (no "Auto"), Lautstärke angleichen, Lückenlose Wiedergabe, Autoplay. No crossfade and no hardware decoding.
- Kurzbefehle: read-only `LabeledContent` list (see below).
- Footer: "Spotifly 2.4.1 (7245) · Librespot 0.6.0".

### Player bar (custom layout, standard parts)
Left to right:
1. Shuffle (`Toggle .button`), Prev, Play/Pause (38pt), Next, Repeat (3 states: off/all/one; "one" adds a small "1" badge).
2. Cover 40pt (6pt radius), title (semibold) / artist (secondary), time "m:ss / m:ss", and a thin seek `Slider` underneath.
3. Heart (red when liked), track `Menu`, AirPlay button (opens Wiedergabe auf), volume icon + `Slider` (72pt), and an Inspector toggle.

Responsive behavior: under 680pt bar width the volume control is hidden; under 640pt the time label is hidden.

### Inspector "Jetzt läuft"
280pt artwork, title / subtitle · artist / album, then "Als Nächstes" (next 8 tracks, tap to jump).

## Interactions
- Track rows: single click selects (accent-colored row), double click plays, right click opens `.contextMenu`. The playing row is accent-colored and its number is replaced by an equalizer animation.
- Like toggle is optimistic and syncs via `PUT/DELETE /me/library`. Follow and Save use the same endpoint.
- Back/forward follow the navigation history.
- Shortcuts:
  - Leertaste: Play/Pause
  - ⌘→ / ⌘←: next / previous
  - ⌘↑ / ⌘↓: volume
  - ⌘L: like
  - ⌘F: search
  - ⌃⌘S: sidebar
  - ⌥⌘I: inspector
  - ⌘,: settings
- Media keys and Control Center via `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`.
- Prev restarts the current track if more than 4s have played; otherwise it goes to the previous track.

## State
`screen`, nav history, `playing`, `shuffle`, `repeat (off|all|one)`, `queue`, `currentIndex`, `position`, `volume`, `sidebarVisible`, `inspectorVisible`, liked/followed/saved sets, search query/scope/offset, and settings in `@AppStorage`.

## Design tokens
- Accent color (`AccentColor` asset): **#1DB954**. Alternates shown in Tweaks: #007AFF, #FF2D55, #AF52DE.
- Everything else uses system semantic colors (label, secondaryLabel, separator, red #FF3B30/#FF453A dark), SF Pro, and system control sizes. Supports light and dark.
- Type used: large title 26–30 bold, title2 17 bold, headline 13 semibold, body 13, subheadline 11, caption 10.
- Spacing: content inset 28pt, card gap 16pt, table rows 44pt, Form rows ≥38pt.
- Corner radii: artwork 4 (32pt list), 6 (40pt), 10 (132pt+).

## API scope
See `Feature-Audit.md` for what was removed or changed due to Spotify Web API restrictions (Feb 2026 Dev-Mode changes) and the full endpoint list.

## Assets
Cover art in the prototype is generated placeholders (`CoverArt.jsx`). Use `AsyncImage` with the API image URLs. Use SF Symbols for icons (the prototype uses hand-drawn SVG stand-ins).

## Files
- `design/Spotifly Native.html`: entry point
- `design/native/App.jsx`: state, routing, tweaks
- `design/native/Shell.jsx`: sidebar, toolbar, player bar, inspector, settings window
- `design/native/Screens.jsx`: Home, Search, Queue, Wiedergabe auf, Profil, TrackTable
- `design/native/Library.jsx`: Favoriten, Playlists, Alben, Künstler
- `design/native/ui.jsx`: control kit (each component maps to its SwiftUI control)
- `design/native/native.css`: styles
- `design/components/*`: mock data, icons, placeholder covers
- `Feature-Audit.md`: API audit
