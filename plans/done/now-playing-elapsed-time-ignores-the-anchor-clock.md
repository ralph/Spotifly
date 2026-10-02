# Control Center's elapsed time, and Previous, read the position without the time since it

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/ViewModels/PlaybackViewModel.swift` (`applyNowPlayingTiming`,
`handlePlaybackStateUpdate`, `handlePlaybackStarted`, `performSeek`, `interpolatedPositionMs`,
`hasPrevious` and `currentPositionMs`, both removed), `Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-10-02, in the review of `plans/done/position-behind-after-a-reconnect.md`

## Summary

The bar shows `interpolatedPositionMs`: the anchor's position plus the time since its anchor
time. Control Center's elapsed time and the Previous button read `currentPositionMs`, the
anchor's position alone, as the position now. Control Center also heard nothing when another
device seeked. Control Center now gets the bar's position and hears every re-anchor, Previous is
enabled with a track, and the anchor's position alone is no longer a property anyone can read.

## Problem

### Seen

On a build of `main`, mirroring a silent librespot device (`connect_measure`) playing "Never
Know" (175 s). Control Center's state was read from outside the app through MediaRemote
(`MRNowPlayingRequest.localNowPlayingItem`, from JavaScript for Automation; unsigned tools get
nothing):

- **A seek on the other device** (from the web player, at 19:32:37): Spotifly's anchor moved
  `127042 -> 22126`, but Control Center still held the pair published at 19:31:08, `elapsedTime
  48.864`, rate 1. At 19:32:40 it showed **140.7 s** for a track at about **25 s**.
- **Previous on a first track**: the device restarted the album at 0:00 while Spotifly watched,
  anchoring at 202 ms. Pressed 11 s into the track (19:36:20), the button sent nothing: it was
  disabled, and stayed so until the device's next report moved the anchor past 3 s, which
  librespot sends about every 10 s. This Mac's own playback re-anchors only on a change or a
  drift correction, so there it stays disabled for the whole track (read from the code; not
  played aloud to check).

### Why

- **`applyNowPlayingTiming` published `currentPositionMs`.** macOS runs the elapsed time on
  from the moment it is published, at the published rate. An anchor is from the moment it was
  set, and a remote report's anchor is back-dated by the report's age, so a publish after the
  anchor (the queue's metadata, the bar's metadata load) was behind by the time between.
- **A re-anchor on the same track published nothing.** `handlePlaybackStateUpdate` republished
  only on a track change, the first duration, or a change of `isPlaying`. A seek on another
  device changes none of them.
- **`hasPrevious` compared `currentPositionMs` with 3000.** The view reads it once per redraw
  and the clock is not observed, so even the interpolated position would only have been
  re-read at the next unrelated redraw.

## Solution

- **Control Center gets the bar's position:** `applyNowPlayingTiming` publishes
  `interpolatedPositionMs`, clamped to the duration.
- **Every playback state update republishes the timing**: the full entry on a track change, else
  `updateNowPlayingPosition()`, which writes the duration too, so the first duration's own full
  update went. Updates arrive only when something changed, a few a minute while another device
  plays.
- **Two re-anchors that published first or not at all:** `handlePlaybackStarted` now re-anchors
  before it publishes, where the new track went out with the old track's position; and a seek
  that could not be sent puts Control Center back with the bar.
- **Previous is enabled whenever a track is loaded**, by the bar's `hasPlayback` as shuffle is;
  `hasPrevious` is gone. It always does something: it goes back a
  track, or restarts this one where there is none to go back to, on this Mac
  (`LibrespotClient.previous()`) and on a remote device (`403 no_prev_track` answered with a seek
  to 0). The three-second rule only hid a restart in a track's first seconds, and switching it
  on at the right moment would need a timer for one button. Spotify's and Apple's players keep
  Previous enabled too.
- **`currentPositionMs` is gone**, inlined into `interpolatedPositionMs` for a position that is
  not advancing, so no reader can take the anchor for the position now again.
- **Not changed:** while the session is down, the bar pins the position and Control Center runs
  on at rate 1. The other device plays on meanwhile, so Control Center is the nearer of the two,
  and the bar catches up to it when the session returns.

## Verification

- [x] **Live, the seek**, on the fix, the same setup: the web player seeked the device at
      19:34:14, Spotifly anchored at 22124 ms and published `elapsedTime 22.168`. At 19:34:18
      Control Center gave **26.008 s**, and the bar's anchor gave 26.013 s for the same moment.
- [x] **Live, the launch:** Control Center started from the bar's position, within the half
      second it takes macOS to take the entry while the app starts up.
- [x] **Live, Previous:** the device restarted the album's first track at 19:36:52 (anchor 202 ms,
      no earlier track); pressed at 19:37:04, 11 s in, Previous sent the command and restarted
      it. The `main` build sent nothing in the same situation.
- [x] Unit tests: 590 pass. None covers these paths, which run through the live client and the
      system's Now Playing center.
