# The volume slider writes another device's volume as this Mac's

Status: **Open**
Components: `Spotifly/ViewModels/PlaybackViewModel.swift` (`volume`, `remoteVolume`,
`becameLocalActiveDevice`, the volume debounce, `startLocally`),
`Spotifly/Views/NowPlayingBarView.swift` (`setVolume`)
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

Proposed: `volume` is only ever this Mac's.
- A slider move goes through one view model method that writes `remoteVolume` while another
  device is active (by `PlayerModel.activeDeviceId` against `ownDeviceId`, as `LoggedInView`
  decides `becameLocal`/`becameRemoteActiveDevice`) and `volume` otherwise.
- Two debounces, one per destination: `volume`'s goes to this Mac's client, always;
  `remoteVolume`'s to the active device over spclient.
- Then `becameLocalActiveDevice` only clears `remoteVolume`, `startLocally` no longer pushes the
  volume, and `volume`'s `didSet` saves unconditionally.

## Verification

With the silent librespot device active and Spotifly mirroring it: a move of Spotifly's slider
reaches the device (its volume in the cluster), and Spotifly's own volume in the cluster and its
saved volume stay put. Then this Mac takes over: its volume is what it was, with no restore.
