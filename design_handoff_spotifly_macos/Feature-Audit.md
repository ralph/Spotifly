# Spotifly — Feature- & Control-Audit

Stand: 7. Okt. 2026. Geprüft gegen die aktuelle Spotify Web API (inkl. Dev-Mode-Änderungen Feb. 2026), nicht gegen open.spotify.com im Browser.

## Entfernt (nicht verfügbar)
- Monatliche Hörer, Wiedergabezahlen („Plays“): `followers`/`popularity` wurden aus den Antworten entfernt, monatliche Hörer gab es in der API nie.
- „Beliebt“ (Top-Titel eines Künstlers): `GET /artists/{id}/top-tracks` wurde entfernt.
- Genre-Kacheln beim Suchen: `/browse/categories` wurde entfernt.
- Profil: Statistiken (Minuten, Genres, Mitglied seit), Abo-Stufe, Land: `product`/`country` wurden aus `GET /me` entfernt, Hörstatistiken gibt es in der API nicht.
- „Meine Daten exportieren“, Songtexte: keine API vorhanden.
- Warteschlange leeren / umsortieren / entfernen: die API kann die Warteschlange nur lesen und Titel anhängen.
- Crossfade und Hardware-Decodierung: Librespot unterstützt keinen Crossfade, VideoToolbox decodiert kein Vorbis.
- Album-Label: das Feld wurde entfernt.

## Geändert
- Titel fremder Playlists: Spotify liefert `items` nur noch für eigene oder gemeinsame Playlists → stattdessen ContentUnavailableView. Abspielen geht trotzdem.
- Suche: höchstens 10 Ergebnisse pro Anfrage → in den Bereichen gibt es „Mehr laden“ (über `offset`).
- „Top-Alben“ → „Zuletzt gehört“ (`/me/player/recently-played`) und „Top-Titel“ mit Zeitraum-Picker (`/me/top?time_range`).
- Folgen/Speichern läuft über `PUT/DELETE /me/library`.
- Qualität: 96/160/320 kbit/s (Librespot), kein „Auto“.
- Kurzbefehle: Leertaste für Play/Pause (statt ⌘K), ⌘F für Suchen.
- Einstellungen: eigenes Settings-Fenster (⌘,) statt Seitenleisten-Eintrag.

## Verfügbar & genutzt
`/me`, `/me/top/{artists,tracks}`, `/me/player/recently-played`, `/me/tracks` (mit `added_at`), `/me/albums`, `/me/following`, `/me/playlists`, `/artists/{id}`, `/artists/{id}/albums?include_groups`, `/albums/{id}`, `/search`, `/me/player`, `/me/player/devices`, Gerät wechseln, `/me/player/volume`, `/me/player/queue`.

## SwiftUI-Zuordnung (Tweak „SwiftUI-Controls markieren“ zeigt sie per Hover)
- Seitenleiste: NavigationSplitView + List(.sidebar), Section, .badge
- Bibliothek: dreispaltige NavigationSplitView, List(selection:), .searchable
- Titellisten: Table mit sortOrder, .contextMenu
- Toolbar: ToolbarItem, ControlGroup, ShareLink, Menu
- Buttons: .borderedProminent, .bordered, .borderless, role .destructive
- Einstellungen, Wiedergabe auf, Profil: Form(.grouped), Section, LabeledContent, Toggle(.switch), Picker(.menu/.segmented), Slider, DisclosureGroup
- AirPlay: AVRoutePickerView (AVKit, per NSViewRepresentable)
- Leere Zustände: ContentUnavailableView
- „Jetzt läuft“: .inspector
- **Nicht standardisiert:** Der Player unten ist ein eigenes Layout (.safeAreaInset + .glassEffect), gebaut nur aus Standard-Buttons und -Slidern. Ein fertiges „Player-Bar“-Control gibt es in SwiftUI nicht.
