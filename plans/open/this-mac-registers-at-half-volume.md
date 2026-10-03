# This Mac shows at half volume on other devices until it plays

Status: **Open**, unmeasured
Components: `Spotifly/SwiftLibrespot/Connect/SpircController.swift` (`volume`),
`Spotifly/SwiftLibrespot/Core/LibrespotSession.swift` (`connect`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`logicalVolume`, `setVolume`),
`Spotifly/ViewModels/PlaybackViewModel.swift` (`startLocally`, the volume debounce)
Found: 2026-10-03, in the review of `plans/done/playback-view-model-mirrors-the-player.md`

## Summary

Every session registers this Mac on Spotify Connect at 50%: `SpircController` starts at
`65535 / 2`, and `LibrespotSession.connect` builds it without the client's `logicalVolume`. The
saved volume reaches Spirc only through `LibrespotClient.setVolume`, which a local start calls
(`startLocally`), and the slider while this Mac is active. So after a launch, a rebuild or a
reconnect, other devices draw this Mac's slider at half until it plays. A session that only
mirrors another device never corrects it: the debounce sends a slider move to that device
instead.

## Solution

Proposed: the client knows the saved volume from `initialize` (the facade's
`syncSettingsFromUserDefaults` reads it already), passes `logicalVolume` to `SpircController` at
connect, and `startLocally` stops pushing it on every start.

## Verification

The web player's device list shows each device's volume: Spotifly's there, before and after a
launch with a saved volume other than 50%, with nothing played.
