# The playback view model keeps its own copy of the player's playback state

Status: **Open**, partly done: 2026-10-02, shuffle is read from the player, and a local start no
longer writes the track and the playing state ahead of it; 2026-10-03, `isPlaying` is taken
from the snapshot alone, never from the client's flag, and the drift poll no longer corrects
it. What is left is named below, with where it is written
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
  - the mirror, in `handlePlaybackStateUpdate`: **done**, `state.isPlaying` alone. It read
    `SpotifyPlayer.isPlaying` while this Mac was the active device and the cluster's
    `isPlaying && !isPaused` otherwise;
  - **done:** `checkDriftAndSync()`, once a second while this Mac was active, from
    `SpotifyPlayer.isPlaying`, re-anchoring the position when it differed;
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

Done in the second step, **which `isPlaying`**:
- The client's flag, `SpotifyPlayer.isPlaying`, is `latest.playback?.isPlaying` in
  `LibrespotClient`: the same field of the same stream of snapshots the player model applies,
  read at its newest. Both places that build a `PlaybackState` already make `isPlaying` mean
  playing and not paused (`publishPlaybackState`: `playing && !paused`; `mirror`: `isPaused` is
  `!playing`), so `isPlaying && !isPaused` was `isPlaying`.
- Measured, they never disagreed (below), so `handlePlaybackStateUpdate` takes
  `state.isPlaying`, and the drift poll's correction of `isPlaying`, there for the Rust bridge's
  missed callbacks, is gone.
- They differ in one case, which the measurement could not reach: a snapshot with no playback,
  published when a load fails, a context has nothing left to play, another device takes over,
  or the session goes. The flag read it as not playing, while `handlePlaybackStateUpdate`
  returned early on `nil`, so the bar went on playing until the poll, or the cluster's next
  report, said otherwise. It now stops on `nil` itself, its clock frozen where it had got to.
- Still a copy, deliberately: computed from `player.playback`, `isPlaying` would change at the
  player model's `apply`, while the position anchor moves only when `handlePlaybackStateUpdate`
  runs, on the next delivery of `Observations`. In between, `interpolatedPositionMs` would run
  from a paused anchor, or stop at a stale one, and a frame drawn there jumps. The copy is
  written in the same call as the anchor. It can become computed with the clock, in step 3.

Next, in this order, each measured before it changes:
1. **Logout.** `clearPlaybackState()` could become the player model's own reset, if the client
   publishes an empty snapshot at shutdown.
2. **`trackDurationMs`, the position anchor and `isPlaying`**, last, since the clock depends on
   them. With them, the local start's re-anchor, which repeats what the report already did, and its
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

### Second step, `isPlaying` (2026-10-03)

With throwaway logs, against the old code, and local playback muted by a throwaway that set
the renderer's volume to 0:

- Every snapshot, through a local start, a pause, a resume and two skips
  (`SPOTIFLY_DEBUG_AUTOPLAY`, `…_PAUSE_AFTER`, `…_NEXT_AFTER`), then the silent librespot device
  taking over, skipping and quitting: the client's flag equalled `state.isPlaying` each time,
  and `isPlaying && !isPaused` equalled `isPlaying`. The drift poll's check never differed.

With the change:

- Sampled twice a second through the same start, pause, resume and skips: the bar's
  `isPlaying` and the client's flag agreed in all 61 samples (15 playing, 12 paused,
  34 playing).
- The librespot device taking over: the bar's play button read "Pause" while it played, and
  "Wiedergeben" once it quit.
- A failed load, faked with a throwaway that called `playbackFailed` ten seconds into a track:
  the bar said not playing 49 ms later, its position frozen at 10103 ms, and Control Center's
  rate was 0. The cluster's own report followed 70 ms after that. Before, the bar relied on the
  poll, within a second, or on that report.
