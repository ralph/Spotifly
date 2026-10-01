# A skip by hand onto a withheld track stops playback

Status: **Open**, not planned. Read from the code and librespot; nothing observed.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`advanceUserInitiated`,
`previous`, `skip(toNext:uri:)`, `skip(toPrevious:uri:)`, `loadAndPlay`),
`Spotifly/SwiftLibrespot/Public/AutoAdvance.swift`
Found: 2026-10-01, working on `plans/done/unplayable-track-attempts-cost-and-show.md`

## Summary

Next, Previous and a jump in the queue step over the tracks they know are withheld. One they do
not know yet, from a context the app never listed and not fetched ahead, is loaded, fails, and
playback stops there with "not available". Auto-advance would have gone on past it, and so does
librespot.

## Problem

- **Here:** `advanceUserInitiated`, `previous` and the two jumps call `loadAndPlay`, whose failure
  goes to `playbackFailed`: the local state is cleared, the device lets go of the active role,
  and the bar shows the error. The track is marked, so the next press steps over it.
- **librespot**, on `PlayerEvent::Unavailable` for the current track, marks it and calls
  `handle_next` (`connect/src/spirc.rs`), whichever way the track was started.
- **Auto-advance** already goes on past it (`AutoAdvance.run`).

Likely cases: a Next in a track's first ten seconds, before the fetch-ahead, in a playlist or
radio started from a phone; a double-click on a row of the Mac's queue from another device.

## Solution

Not planned. Probably: the manual skips run through `AutoAdvance.run` in their direction, as
auto-advance does, after `loadAndPlay`'s Premium guard, and stop only on a failure that is not
the track's. Previous would step back past it the same way.

## Verification

Not defined yet.
