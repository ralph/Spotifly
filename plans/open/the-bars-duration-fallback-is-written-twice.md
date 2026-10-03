# The now-playing bar's duration fallback is written twice

Status: **Open**, small
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

Proposed: one, in the view model (`displayedDurationMs`, say, nil while unknown), which both
read. The bar's 0 for "unknown" maps to its `--:--` today; check that it still shows that.

## Verification

A unit test of the rule if the view model's store can be set up in one; otherwise a live check
that the scrubber and Control Center show the same length on the first frames of a new track.
