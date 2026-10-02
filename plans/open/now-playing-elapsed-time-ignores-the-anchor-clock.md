# Control Center's elapsed time, and Previous, read the position without the time since it

Status: **Open**, not planned. Read from the code, not measured.
Components: `Spotifly/ViewModels/PlaybackViewModel.swift` (`applyNowPlayingTiming`,
`hasPrevious`, `currentPositionMs`)
Found: 2026-10-02, in the review of `plans/done/position-behind-after-a-reconnect.md`

## Summary

The bar shows `interpolatedPositionMs`: the anchor's position plus the time since its anchor
time. Two other readers take `currentPositionMs`, the anchor's position alone, as the position
now:

- **`applyNowPlayingTiming`** publishes it as `MPNowPlayingInfoPropertyElapsedPlaybackTime`, with
  rate 1.0 while playing. A remote report is back-dated by its age, which can be tens of
  seconds ("timestamp was 25117ms ago" in that plan's log), so Control Center and the media keys'
  HUD start that far behind the bar. They stay behind until a play, pause or track change
  publishes again, and each of those is stale the same way. A republish some time after an
  anchor, such as after track metadata arrives, is behind by that time too.
- **`hasPrevious`** compares it with 3000 ms. Playing from an anchor at 0, it stays below 3 s for
  the whole track, so Previous counts as unavailable on a first track with no previous tracks.

## Solution

Not planned. Probably both read `interpolatedPositionMs`. Then check what republishes the Now
Playing timing: a seek or a back-dated report while playing should publish too, or Control
Center keeps extrapolating from the old pair.

## Verification

None yet. Check against the bar: Control Center's elapsed time while another device plays a
track that started well before the Mac learned of it, and Previous on a context's first track.
