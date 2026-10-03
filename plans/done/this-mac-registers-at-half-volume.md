# This Mac shows at half volume on other devices until it plays

Status: **Done** (2026-10-03)
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

The client knows the saved volume from `initialize` (`SpotifyPlayer.initialize` reads it, as it
did for the output gain), keeps it as `logicalVolume`, and passes it to each session's
`connect`, which registers `SpircController` at it: the first connect and every recovery. A
change goes on through `setVolume` as before.

From the review: the slider's debounce sent a move to this Mac's client only while this Mac
was the active device, so a move while no device was active went nowhere, and the cluster kept
the old volume. It now goes to the client then too, whether the player is up or not.

The push on every local start stays, against the plan's proposal: a remote device whose volume
Connect does not say leaves the slider showing, and saving, this Mac's volume, while the
debounce sends the move to that device; the start is what tells the client. Unchanged,
`SpircController.updateVolume` reports nothing, so it costs nothing.

## Verification

The cluster's device list, which other devices draw their sliders from, read by a throwaway
in the running app, with nothing played:

- **Before:** saved 0.606, the slider 0.606, the cluster `Spotifly:50` at 6, 12 and 20 s.
- **After:** `Spotifly:61` at 6, 12 and 20 s.
- **A recovery** (`SPOTIFLY_DEBUG_DROP_AP_AFTER=8`): the transport lost at 9 s, the device
  registered again, and the cluster said 61 before and after.
- **A move while no device was active** (a throwaway set the volume to 0.42, then back): the
  cluster said 42 three seconds later, and 61 again after the restore, with a `volumeChanged`
  PutState each time; the saved value went back to 0.6059375.
- A unit test: `SpircController` registers at the volume it is given. 623 tests pass.
