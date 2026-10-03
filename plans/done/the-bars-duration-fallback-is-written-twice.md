# The now-playing bar's duration fallback is written twice

Status: **Done** (2026-10-03)
Components: `Spotifly/Views/NowPlayingBarView.swift` (`currentDurationMs`),
`Spotifly/ViewModels/PlaybackViewModel.swift` (`effectiveNowPlayingDurationMs`)
Found: 2026-10-03, in the simplify review of `plans/done/playback-view-model-mirrors-the-player.md`

## Summary

A new track starts without the stream's length, so two places fall back to the store's: the
bar's `currentDurationMs`, for the scrubber, and the view model's
`effectiveNowPlayingDurationMs`, for Control Center. Same rule, written twice, and they already
differ: the bar returns 0 for an unknown length, the view model nil, and the bar reads the store
through its own `currentTrack`, the view model through `currentNowPlayingTrack`.

## Solution

One rule, in the view model: `PlaybackViewModel.displayedDurationMs`, nil while unknown, which
Control Center's timing and the bar's scrubber both read; the rule itself is the pure
`displayedDuration(streamMs:storedMs:)`, so it is unit-tested. The bar maps nil to 0, which
shows "0:00", as its 0 did before (not `--:--`, as this plan had it).

## Verification

- Unit tests: the stream's length wins over the store's, the store's stands in while the
  stream has none, and with neither there is none.
- Live, a muted album start and two skips: the scrubber's accessibility value and Control
  Center's duration agreed on each track (3:35 and 215.205 s, 2:48 and 168.821 s, 3:21 and
  201.759 s).
- 625 unit tests pass.
