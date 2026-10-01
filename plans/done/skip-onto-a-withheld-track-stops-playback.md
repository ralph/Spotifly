# A skip by hand onto a withheld track stops playback

Status: **Done** 2026-10-01. Every load now goes on past a track Spotify withholds, in its
direction, as auto-advance did. Seen in the running app; see Verification.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`loadAndPlay`, `previous`,
`skip(toNext:uri:uid:)`, `skip(toPrevious:uri:uid:)`, `autoAdvance`, `rewindContext`),
`Spotifly/SwiftLibrespot/Public/AutoAdvance.swift`
Found: 2026-10-01, working on `plans/done/unplayable-track-attempts-cost-and-show.md`

## Summary

Next, Previous and a jump in the queue stepped over the tracks they knew were withheld. One
they did not know yet, from a context the app never listed and not fetched ahead, was loaded,
failed, and playback stopped there with "not available". Auto-advance went on past it, and so
does librespot. Now every load does: a skip, a play and a handover too.

## Problem

- **Here:** `advanceUserInitiated`, `previous` and the two jumps called `loadAndPlay`, whose
  failure went to `playbackFailed`: the local state was cleared, the device let go of the active
  role, and the bar showed the error. The track was marked, so the next press stepped over it.
- **librespot**, on `PlayerEvent::Unavailable` for the current track, marks it and calls
  `handle_next` (`connect/src/spirc.rs`), whichever way the track was started.
- **Auto-advance** already went on past it (`AutoAdvance.run`), with its own copy of the wiring.

Likely cases: a Next in a track's first ten seconds, before the fetch-ahead, in a playlist or
radio started from a phone; a double-click on a row of the Mac's queue; a radio's or a phone's
play of a context the app never listed.

## Solution

- **`loadAndPlay` runs `AutoAdvance.run`**, the rule auto-advance followed: only
  `trackUnavailable` is passed over, with "Skipped, not available" in the bar, and any other
  failure gives playback up as before. It is the one load path: the skips, a play, a handover,
  the rewind at a context's end, and auto-advance, which keeps only its logging.
- **A direction.** `AutoAdvance.Direction.backward` steps with `PlaybackQueue.back(skipping:)`,
  for Previous and a jump to a previous row. When nothing further back plays, the run ends on
  the withheld track and the client goes on from it as Next would, which gets back to the track
  Previous was pressed on.
- **The start position is the named track's.** A track the run goes on to starts at the top.
- **A context with nothing that plays stops.** `rewindContext` used to fall back to the first
  track when none was known to play, and a load that now goes on past the end would come back
  to it. It stops instead, named after the album or playlist ("Not available on Spotify: …");
  a single track or a bare list has no name, and the run's own message said it.
- **Auto-advance refused for Premium** gives playback up: the guard throws before any load,
  which used to be reached only through a failed load.

What is not reachable live: Previous onto a withheld track nobody knew of. The history holds
tracks that played here and ones that failed, which are marked, so such a track would have to
come from somewhere else. The backward run is unit-tested.

## Verification

- [x] Build, 484 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. Two new tests:
      a backward run passes a withheld track and plays the one before it; with nothing further
      back, it ends on the withheld track.
- [x] Live, 2026-10-01, on the Mac, with Liked Songs (321 tracks) started by
      `SPOTIFLY_DEBUG_AUTOPLAY` and a throwaway hook, never committed, that started it at a
      given track, so the app had never listed it and did not know "Girlfriend (feat. Dâm-Funk)"
      at index 196 was withheld:
  - **Next** four seconds into "Today Is a Gift", before the fetch-ahead: `0 file(s)` for
    Girlfriend, "Skipping … not available", and "Tilted" playing 105 ms after the press. No
    release in between: the first report after the press named Tilted, playing. A second Next
    went on to "Twist in My Sobriety".
  - **A double-click on Girlfriend's row** in the app's queue, two tracks ahead: passed over,
    Tilted playing 70 ms later; the row then greyed in the history.
  - **Previous** from Tilted stepped back over Girlfriend, now known, to "Today Is a Gift"
    without loading it.
  - **A play starting on Girlfriend:** passed over, Tilted playing 18 ms later.
  - **The end of "Today Is a Gift"**, gapless: the fetch-ahead had found Girlfriend withheld,
    and Tilted followed without a gap. With gapless off, the end of a track goes through
    `autoAdvance`; not run live.
