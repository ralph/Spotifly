# Redesign: Wiedergabe auf (Playing On)

Status: **Done**, 2026-10-21, PR #208. Fourth of the stacked redesign PRs. The output name
following a switch of the system output is not seen live: only the user can switch it
Components: `Spotifly/Views/SpeakersView.swift`, `Spotifly/Views/Components/ConnectionStatusView.swift`,
`Spotifly/Views/AirPlayRoutePickerView.swift`, `Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Wiedergabe auf"),
`design/native/Screens.jsx` (`NSpeakers`)

## Summary

The Speakers page becomes the handoff's grouped `Form` with three sections: Spotify Connect
(devices, the active one with its volume), AirPlay (the output picker) and Verbindung (status,
a details disclosure, reconnect).

## Problem

The page draws its own title row above an inset `List`, Connect devices are custom button rows
with the volume as text, AirPlay is a bare picker icon, and the connection is a card of its own
with a status badge, a divider-separated table and a full-width button — none of it the standard
form the handoff asks for, and the page title is drawn twice (toolbar and header).

## Solution

### API

Nothing new. Devices, their volume and the active one come from the cluster
(`PlayerModel.devices`, `activeDevice`); selecting one is `DeviceService.transferPlayback(to:)`;
the active device's volume is `PlaybackViewModel.sliderVolume` / `setVolumeFromSlider`, which
already moves this Mac's or the active remote device's. The connection is
`PlayerModel.connection` (session state, connected since, device id, last error, reconnect
attempts) and reconnect is `PlaybackViewModel.forceReinitialize()`. The output device's name is
CoreAudio's default output device (`kAudioHardwarePropertyDefaultOutputDevice`, its
`kAudioObjectPropertyName`).

### Layout

`Form` with `.formStyle(.grouped)`:

- **Spotify Connect**, footer "Zeigt alle Geräte, die gerade mit deinem Konto verbunden sind.":
  one row per device — a 28 pt rounded tile with its symbol (accent fill when active), the name
  over "type · Aktiv", a checkmark when active. A click transfers playback. Under the active
  row, a volume slider with "N %", greyed with the reason when the device refuses volume. The
  enable-this-Mac row and the Premium notice stay as they are.
- **AirPlay**, footer "Wählt einen AirPlay-Empfänger für die Ausgabe dieses Macs. …": a row
  "Ausgabegerät" with the current output's name under it and the `AVRoutePickerView` as its
  control, enabled while this Mac plays, as today. The picker keeps doing what it does today
  (route this Mac's output); `plans/open/spotifly-only-airplay.md` (#202) will later put
  Spotifly's audio alone behind it, which is why the handoff's picker sits here.
- **Verbindung**: "Status" with a green or orange dot and "Verbunden seit …" (relative), a
  `DisclosureGroup("Details")` holding Sitzung, Geräte-ID (selectable), reconnect attempts and
  the last error, and a "Neu verbinden" row ("Nur nötig, wenn die Wiedergabe hängt.") with a
  bordered button.

The handoff's toolbar "Geräte suchen" refresh is left out: the device list is pushed by the
cluster as devices come and go, and there is nothing to ask for again — the app removed a
refresh that did nothing on the queue for the same reason (`plans/done/queue-refresh-button-does-nothing.md`).
The handoff's details rows "Audioausgabe … 44,1 kHz" and "Stream … 320 kbit/s" are left out
unless the player reports them; the bitrate setting is not what a track actually streams at.

## Verification

- Build, unit tests.
- Run the Debug build, open Wiedergabe auf, screenshot it; transfer to the web player in Chrome
  and back by clicking the rows; drag the active device's volume; open Details; press
  Neu verbinden and see the session come back.

### Result

- Live: the form as in the handoff; a click on "Spotifly, Dieser Mac" transferred playback here
  (arrived paused, as sent) and the row grew its volume slider at 80 %. Device types read as
  names ("Dieser Mac", "Computer", "AV-Receiver") from a mapping beside the icon one; this Mac is
  told by `PlayerModel.ownDeviceId`, and AirPlay is enabled by `PlayerModel.isPlayingHere`
  rather than by the device being named "Spotifly".
- The output device's name follows the default output through a Core Audio listener while the
  page shows (a review and Codex both found it went stale when read once).
- The localization tests caught a bare `"\(typeName)"` literal extracted as the key "%@".
- The Details disclosure holds reconnect attempts, the device id and the last error; the
  handoff's "Sitzung" row repeated the status above it and is left out.
