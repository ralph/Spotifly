# The playback view model keeps its own copy of the player's playback state

Status: **Open**, not planned. Found reviewing the store; deliberately left out of
`plans/open/state-held-twice.md`, which it would have made far riskier
Components: `Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/Store/PlayerModel.swift`,
`Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-10-02, reviewing the store against current practice

## Summary

`PlaybackViewModel` copies `isPlaying`, `currentTrackUri`, `trackDurationMs` and
`isShuffleEnabled` out of `PlayerModel.playback` in `handlePlaybackStateUpdate`, and views read
the copies. It is the largest remaining place where the UI holds player state twice.

## Problem

- **Plain mirrors.** `isShuffleEnabled = state.shuffle` is only ever written from the player's
  state, so it could be computed.
- **Mirrors with local exceptions.**
  - `isPlaying` reads `SpotifyPlayer.isPlaying` while this Mac is the active device, and the
    cluster's state otherwise.
  - A local start sets `currentTrackUri` and `isPlaying` before the player reports them
    (`handlePlaybackStarted`).
  - Logout clears them (`clearPlaybackState`).
- **The position clock.** `trackDurationMs` and the position anchor feed `interpolatedPositionMs`.
  Several done plans tuned that clock, among them
  `plans/done/seek-bar-jumps-between-two-position-clocks.md` and
  `plans/done/stale-cluster-timestamp-parks-the-progress-bar.md`.

So most of it is not a pure copy, but it is a second owner, and two owners of one fact drift.

## Solution

Not planned. A first step with no risk: make `isShuffleEnabled` computed from
`player.playback?.shuffle`. The rest needs each local exception named, measured, and given a
home: in `PlayerModel` as an optimistic overlay, or in the client's snapshot.

## Verification

None yet.
