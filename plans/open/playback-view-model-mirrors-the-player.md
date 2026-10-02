# The playback view model keeps its own copy of the player's playback state

Status: **Open**, partly done 2026-10-02: shuffle is read from the player, and a local start no
longer writes the track and the playing state ahead of it. What is left is named below, with
where it is written
Components: `Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/Store/PlayerModel.swift`,
`Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-10-02, reviewing the store against current practice; deliberately left out of
`plans/done/state-held-twice.md`, which it would have made far riskier

## Summary

`PlaybackViewModel` copied `isPlaying`, `currentTrackUri`, `trackDurationMs` and
`isShuffleEnabled` out of `PlayerModel.playback` in `handlePlaybackStateUpdate`, and views read the
copies. It is the largest remaining place where the UI holds player state twice. Two owners of
one fact drift.

## Problem

Each copy, with every place that writes it:

- **`isShuffleEnabled`: done.** It was written only from the player's state, so it is now
  computed from `player.playback?.shuffle`.
- **`currentTrackUri`:**
  - the mirror, in `handlePlaybackStateUpdate`, when the reported track differs;
  - `clearPlaybackState()`, at logout, to nil;
  - **done:** `handlePlaybackStarted`, after a local start, wrote the uri the start was given.
    Measured on an album start (2026-10-02): the player's report, with the right track and
    playing, reached the view model 158 ms before that write, which then replaced the track
    with the album's uri until the next report, 12 ms later in that run, and nothing
    guarantees one soon. For a playlist the same; for a track Spotify withholds, the track the
    player stepped over. It now leaves both to the report.
- **`isPlaying`:**
  - the mirror, which reads `SpotifyPlayer.isPlaying` while this Mac is the active device and
    the cluster's `isPlaying && !isPaused` otherwise;
  - `checkDriftAndSync()`, once a second while this Mac is active, from
    `SpotifyPlayer.isPlaying`, re-anchoring the position when it differs;
  - `clearPlaybackState()`, at logout;
  - **done:** the local start's `true`, which the report had already set.
- **`trackDurationMs`:** set from the report when positive, reset to 0 by `currentTrackUri`'s
  `didSet` on every change of track, and read by the position clock (`interpolatedPositionMs`,
  the overshoot check) and by Now Playing. Several done plans tuned that clock, among them
  `plans/done/seek-bar-jumps-between-two-position-clocks.md` and
  `plans/done/stale-cluster-timestamp-parks-the-progress-bar.md`.

## Solution

Done in the first step:
- `isShuffleEnabled` computed.
- The local start no longer writes `currentTrackUri`, `lastHandledTrackUri` and `isPlaying`.
  What `handlePlaybackStarted` had left, the volume, a re-anchor and a Now Playing refresh, is
  three lines in `startLocally`, which lost the uri it passed along; the refresh is the
  position's only, since the report already published a new track.
- `lastHandledTrackUri` is gone: without the start's write it always equalled
  `currentTrackUri`, so a change of track is read against that.

Next, in this order, each measured before it changes:
1. **Which `isPlaying`.** The active-device branch reads the client's flag, where the report
   carries the same fact; measure whether the two ever disagree (the drift poll exists because
   they once did, on the Rust bridge), and if not, read `player.playback` alone.
2. **Logout.** `clearPlaybackState()` could become the player model's own reset, if the client
   publishes an empty snapshot at shutdown.
3. **`trackDurationMs` and the position anchor**, last, since the clock depends on them. With
   them, the local start's re-anchor, which repeats what the report already did, and its
   volume, which belongs to the player: it knows when its mixer opens.

## Verification

### First step (2026-10-02)

- **Shuffle:** with the silent librespot device active and Spotifly mirroring it, the bar's
  Zufällig sent `player/command` to the device. Its report said `shuffle=true` 257 ms later and
  the button turned green; pressed again, it read "on" from the player and sent "off", and the
  report said `shuffle=false`.
- **A local album start**, with the fix: the audio began at 22:01:35.360, and the player's
  report with the album's first track came 4 ms later. Nothing wrote the album's uri over it.
- **After the review's changes:** the mirrored device's next track, "Sunny Baby", reached the bar;
  a local album start put "Never Know", playing, in Control Center.
- **Before**, measured with a throwaway log on `main`'s code: the report at .398, the
  optimistic write of `spotify:album:…` at .556, the next report at .568.
- 611 unit tests pass.
