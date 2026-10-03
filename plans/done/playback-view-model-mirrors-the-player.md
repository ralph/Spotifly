# The playback view model keeps its own copy of the player's playback state

Status: **Done** in three steps (2026-10-02 and twice on 2026-10-03, under Solution). One copy
stays, deliberately: what the bar shows, written with the position anchor
Components: `Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/Store/PlayerModel.swift`,
`Spotifly/Views/NowPlayingBarView.swift`, `Spotifly/Views/LoggedInView.swift`
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
  - the mirror, in `handlePlaybackStateUpdate`, now `state.isPlaying` alone (second step);
  - **done:** `checkDriftAndSync()`, once a second while this Mac was active;
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
- `handlePlaybackStateUpdate` read the client's flag, `SpotifyPlayer.isPlaying`, while this Mac
  was active, and the cluster's `isPlaying && !isPaused` otherwise. The flag was
  `latest.playback?.isPlaying` in `LibrespotClient`: the same field of the snapshots the player
  model applies, read at its newest. And both places that build a `PlaybackState` make
  `isPlaying` mean playing and not paused (`publishPlaybackState`: `playing && !paused`;
  `mirror`: `isPaused` is `!playing`).
- Measured, they never disagreed (below), so it takes `state.isPlaying`; the drift poll's
  correction of `isPlaying`, there for the Rust bridge's missed callbacks, is gone, and so is
  the flag, which nothing else read.
- They differ in one case, which the measurement could not reach: a snapshot with no playback,
  published when a load fails, a context has nothing left to play, another device takes over,
  or the session goes. The flag read it as not playing, while `handlePlaybackStateUpdate`
  returned early on `nil`, so the bar went on playing until the poll, or the cluster's next
  report, said otherwise. It now stops on `nil` itself, its clock frozen where it had got to.
- Still a copy, deliberately: computed from `player.playback`, `isPlaying` would change at the
  player model's `apply`, while the position anchor moves only when `handlePlaybackStateUpdate`
  runs, on the next delivery of `Observations`. In between, `interpolatedPositionMs` would run
  from a paused anchor, or stop at a stale one, and a frame drawn there jumps. The copy is
  written in the same call as the anchor. It can become computed with the clock, in the last step.

A more general shape, raised in review: keep the last snapshot that had playback, with
`isPlaying` forced false on `nil`, written in the same call as the anchor, and compute
`isPlaying`, shuffle, `canSkipNext`, `canShuffle` and the track from it. On `nil`, shuffle,
computed from `player.playback`, now reads off and the two `can…` flags read true while the bar
keeps the track; that one copy would make `nil` uniform. It needs `currentTrackUri`'s `didSet`,
which resets the duration, reworked.

Done in the third step, **one value for what the bar shows**:
- `isPlaying`, `currentTrackUri` and `trackDurationMs` were three stored copies, the duration
  reset by the track's `didSet`. They are now read from one `ShownPlayback`: the player's last
  report that had playback, stopped when a later one had none, written in the same call as the
  anchor. Shuffle, `hasNext` and `canShuffle` are read from it too, so a report without
  playback keeps them with the track, where reading `player.playback` turned shuffle off and
  Next on.
- It holds no position, which the anchor has: a report that only moves the position is an
  equal write, which the lists reading `currentTrackUri` do not hear. A pause, a change of
  track or of shuffle still reaches them.
- **Logout.** `clearPlaybackState()` stays the view model's, and runs in `shutdownForLogout`,
  after the teardown. Every way out of the account goes through there (`discardGrant`): a
  revoked grant and a refused one did not clear the bar or Control Center, since only Log Out
  called `stop()`. After the teardown rather than before, since its last report has no
  playback: one still on its way would put the track back, and a report without playback
  keeps it. `stop()`, `SpotifyPlayer.stop()` and `LibrespotClient.stop()` had no other caller,
  and are gone; the teardown stops the pipeline first, before anything that needs the network.
  The player model's own reset, which the plan considered, would have needed a new signal for
  "the session is gone" next to "nothing plays", for no gain over this.
- **The local start's re-anchor is gone.** Measured twice: the start returned 229 ms and
  192 ms after the loading report, and 5 ms and 4 ms before the playing one; the re-anchor
  moved the display from 234 ms (197) back to 0, and the playing report anchored it at 0 again
  a few ms later. Every load ends in a playing or paused report, so the report always does it.
- **The local start's volume stays.** It is not the mixer's (the output gain is applied by
  `volume`'s `didSet`), but the Connect volume: `SpircController` registers at 50% and keeps
  that until told, so other devices would draw this Mac's slider at half. That it does so
  until the first start is `plans/open/this-mac-registers-at-half-volume.md`.

Not done, deliberately: computing `isPlaying` and the track straight from `player.playback`.
They would change one `Observations` delivery before the anchor (above), and every report
would reach the lists, position-only ones included.

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

### Third step, one value for what the bar shows (2026-10-03)

Throwaways, not committed: local playback muted, a sampler logging the bar's state each second,
and hooks that toggled shuffle, published no playback without letting go of the active role, faked
a failed load, and ran `shutdownForLogout` without touching the credentials.

- **Start, pause, resume, two skips:** the track, `isPlaying` and the duration followed the
  player model in all 28 samples, the duration the new track's from the first sample after each
  skip.
- **No playback, with shuffle on:** the bar kept the track, stopped at 5989 ms, with shuffle on
  and Next enabled; Control Center's rate was 0 at 5.989 s.
- **A faked sign-out while playing:** right after the teardown, the bar had no track, shuffle off,
  Next disabled, and Control Center said "Spotifly", 0:00, rate 0. No playback report came after.
- **The silent librespot device playing an album:** the bar followed it through its skip, with
  each track's length; when it quit, the bar kept its track, stopped at 9919 ms.
- 617 unit tests pass.

Seen on the way, filed: `plans/open/a-released-track-shows-its-last-reported-position.md`, and
from the review, `plans/open/this-mac-registers-at-half-volume.md`.

