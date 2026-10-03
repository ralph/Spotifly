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

`volume` is only ever this Mac's, and what the slider shows is read, not kept:
- **`sliderVolume`**, **`sliderRefused`** and **`setVolumeFromSlider`** in the view model
  decide which device the slider is for in one place: `PlayerModel.activeRemoteDeviceId`, the
  active device unless it is this Mac. While another device plays, the slider shows its volume
  from the player model, and a drag shows its own value until the device reports a new one;
  a drag goes to that device over spclient and never touches `volume`.
- From the review: `remoteVolume` was a copy of the active device's volume, kept up by two
  `onChange`s in `LoggedInView`'s window branch, which the mini player does not have, so it
  went stale there and the slider could show one device's volume while moving the other's.
  It is gone, with `becameLocalActiveDevice`, `becameRemoteActiveDevice`,
  `remoteDeviceVolumeUpdated` and the `onChange`s.
- Two debounces: `volume`'s goes to this Mac's client and is saved there, once per drag rather
  than once a frame; the remote one goes to the active device. `handleVolumeChange` skips the
  client's echo of a volume set here.
- `startLocally` no longer pushes the volume. The view model owns the saved setting and hands
  this Mac's volume to `SpotifyPlayer.initialize(volume:)`; `SpotifyPlayer.savedVolume` is gone.

## Verification

Live, with throwaways that made the same call the slider makes (`setVolumeFromSlider`) and
logged the view model, what the slider shows, the saved value and the cluster's device list:

- **Another device active** (the silent librespot device, at 100%): the slider showed 1.0 as
  soon as the device was active. A slide to 0.3 showed 0.3 at once, and the device's volume in
  the cluster was 30 two seconds later; sliding back set it to 100 again. This Mac's stayed as
  it was throughout: `volume` and the saved value 0.6059375, its cluster entry 61. When the
  device quit, the slider showed 0.6059375 again, with nothing restored. Before, the same move
  set `volume`, and with it this Mac's output gain, to 0.3 (`NowPlayingBarView.setVolume`).
- **No device active:** a slide to 0.3 set `volume` and the slider at once, and the saved value
  and the cluster's entry for this Mac (30) after the debounce, with one `volumeChanged`
  PutState; sliding back restored 0.6059375 and 61.
- 622 unit tests pass.
