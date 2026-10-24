# On a HomePod, the player can stop answering pause and seek

Status: **Open**, fixed in #220 (`airplay/stalls`) and checked on the Küche HomePod on
2026-10-24; open until a manual run on the HomePod confirms it. The output writes 30 s ahead of
the playhead, and up to 120 s while the playhead stands still though the player is meant to play.
Components: `Spotifly/AudioOutput.swift`
Found: 2026-10-21, rerunning #219's checks on the Küche HomePod: a seek took 18 s, and the app
crashed when it landed (the crash is fixed on #219, 10a9e89).

## Summary

On a HomePod the player's reader takes in everything the output has written almost at once, and
then waits at the end of the stream for more, holding a lock that a seek, a pause and even
reading the item's time wait for. The output writes as the audible playhead moves. So when the
playhead stood still, because a seek had not landed or the receiver had stopped, nothing more was
written, and nothing moved: a seek stayed unfinished while the HomePod played on through its
buffer, pause did nothing, or the playhead froze after a seek. Now the output keeps writing while
the playhead stands still, up to 120 s ahead, which lets the reader go on and the lock go.

## Problem

### What was seen

Times are UTC.

- **2026-10-21, at 10 s written ahead.** Two seeks in about twenty were followed about 5 s later
  by the player pausing itself with an empty buffer. Later a seek never finished: `pause()` set the
  player's rate to 0, the item's timebase kept rate 1, the HomePod played on through eight more
  seeks, each replaced by the next, and through a pause from the web player (−48.6 dB at the Mac's
  microphone, −52.3 dB before); quitting the app silenced it. Earlier a seek finished 18 s late,
  after the item had played on into the next track, and moved the playhead back behind that
  track's start, which crashed the pipeline (fixed on #219).
- **2026-10-24, Ralph's run at 30 s ahead** (`airplay/stalls` before this fix): 20 seeks, two
  failed. The first, right after routing to the HomePod during playback, was "not done after 2 s;
  the item plays at rate 1.0" until the next seek replaced it 8.4 s later. The last landed in
  48 ms, played 0.9 s, and its playhead then stood at 30.4 s for 27 s with the player "Playing".
- **2026-10-24, at 30 s ahead, with diagnostics.** Switching the route to the Mac and back to the
  HomePod during playback, then seeking, hung the app's main thread twice in two, for 89 s and
  84 s. A stack sample of the second: the main thread in `-[AVPlayerItem currentTime]` (the
  diagnostics' call) waiting for a mutex in MediaToolbox; the player's queue and the AirPlay play
  queue waiting for mutexes too; and `com.apple.coremedia.audiomentor` in
  `AudioFileReadPacketData` → `Seekable_DataSource::ReadBytes`, waiting on a condition for bytes
  from the resource loader. The output's decode was retired for the seek, so no bytes came.
- `loadedTimeRanges` around seeks: right after one, about 30 s from the seek target; a few seconds
  later often nothing (`1195.9–1195.9` with the item at 1200 s). The HomePod takes what is written.

### What it points to

The reader waits at the end of the stream with a lock held whenever it has taken everything. That
is harmless while bytes keep coming: they come about once a second, as the playhead moves. It
hangs everything when the playhead does not move, since the output then writes nothing: a seek
that waits for the lock keeps the playhead behind the new run's start (played frames stay 0), a
receiver that stops keeps it still, and either way the output waits for it to move.

## Solution

`AudioOutput.enqueue` keeps 30 s written ahead of the playhead, and while the output means the
player to play (`State.wantsToPlay`) and the playhead has not moved for half a second, up to 120 s.
A resume restamps the playhead, so a pause does not count as standing still. "The playhead stands
still; writing up to 120 s ahead" is logged once each time it starts. A seek still in flight after
2 s is logged with the item's rate, as before.

### Tried and dropped

- **`automaticallyWaitsToMinimizeStalling = true`**: the player never started, waiting for a rate
  of incoming data the output, writing as the playhead moves, never shows.
- **120 s ahead all the time**: 30 seeks and six route switches without a failure, but
  `CMSampleBuffer`s held 85 MB and the footprint rose to 370–414 MB (peak 498 MB), against
  280–295 MB with this rule.
- **Cancelling a seek not done after 1 s and seeking again to where a frozen playhead stands**:
  never triggered in 30 seeks, and cancelling would wait for the same lock on the main thread.

## Verification

- Build, unit tests.
- Küche HomePod, at 10 % in its own slider: playing, then six rounds of switching to the Mac and
  back during playback, each followed by two seeks, then 20 seeks 2–6 s apart. All 32 seeks done
  in 30 ms or less; nothing logged as not done; "stands still" logged once per route switch, as
  the HomePod holds the playhead for about a second taking over. A minute's playback after it:
  footprint 278–294 MB, no dropouts at the microphone.
- To do: Ralph's manual run of the testing plan's AirPlay section on this build.
