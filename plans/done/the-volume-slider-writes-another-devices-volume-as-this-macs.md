# The volume slider writes another device's volume as this Mac's

Status: **Done** (2026-10-03)
Components: `Spotifly/ViewModels/PlaybackViewModel.swift` (`volume`, `remoteVolume`,
`becameLocalActiveDevice`, the volume debounce, `startLocally`),
`Spotifly/Views/NowPlayingBarView.swift` (`setVolume`), `Spotifly/SpotifyPlayer.swift`
(`initialize`, `savedVolume`)
Found: 2026-10-03, in the reviews of `plans/done/this-mac-registers-at-half-volume.md`

## Summary

`PlaybackViewModel.volume` is meant to be this Mac's volume, and is what its output plays at,
what the slider saves, and what this Mac registers at on Spotify Connect. But while another
device plays, the bar's slider writes that device's volume into it too: `NowPlayingBarView.setVolume`
sets `remoteVolume` and `volume` alike. So `volume` is this Mac's only while no other device is
active, and the code around it compensates.

## Problem

What follows from the one value meaning two things:
- **This Mac's output gain** follows a remote device's slider: `volume`'s `didSet` applies it at
  the output (`SpotifyPlayer.setOutputVolume`). Nothing plays here then, so it is not heard, but
  the gain is wrong until something sets it back.
- **`becameLocalActiveDevice`** restores `volume` from UserDefaults when this Mac takes over, and
  pushes it to the client again, to undo that.
- **`SpotifyPlayer.savedVolume`** reads UserDefaults instead of the view model's `volume`, which
  cannot be trusted to be this Mac's.
- **The volume debounce** routes each move by which device is active, since a move of `volume`
  can be either device's.
- **When the active device's volume is not known yet** (the device list lagging behind the
  active id, the one time `remoteVolume` is nil while another device plays), a move is sent to
  that device but saved as this Mac's, and `startLocally` pushes the volume on every start to
  carry such a move to the client.

## Solution

`volume` is only ever this Mac's:
- The slider calls `PlaybackViewModel.setVolumeFromSlider`, which writes `remoteVolume` while
  another device is active (`PlayerModel.activeDeviceId` against `ownDeviceId`, as
  `LoggedInView` decides `becameLocal`/`becameRemoteActiveDevice`), and `volume` otherwise.
- Two debounces: `volume`'s goes to this Mac's client, always; `remoteVolume`'s to the active
  device over spclient.
- `volume`'s `didSet` and `handleVolumeChange` save unconditionally; `becameLocalActiveDevice`
  only clears `remoteVolume`; `startLocally` no longer pushes the volume.
- The view model owns the saved setting, reading and writing it, and hands this Mac's volume
  to `SpotifyPlayer.initialize(volume:)`; `SpotifyPlayer.savedVolume` is gone.

## Verification

Live, with throwaways that made the same call the slider makes (`setVolumeFromSlider`) and
logged the view model and the cluster's device list:

- **Another device active** (the silent librespot device, at 100%): a slide to 0.3 set the
  device's volume in the cluster to 30 within 4 s, and this Mac's stayed as it was: `volume`
  and the saved value 0.6059375, its cluster entry 61. When the device quit, `remoteVolume`
  went back to nil and `volume` was unchanged, with nothing restored. Before, the same move set
  `volume`, and with it this Mac's output gain, to 0.3 (`NowPlayingBarView.setVolume`).
- **No device active:** a slide to 0.3 set `volume` and the saved value to 0.3, and the
  cluster's entry for this Mac to 30 (a `volumeChanged` PutState); sliding back restored
  0.6059375 and 61.
- 622 unit tests pass.
