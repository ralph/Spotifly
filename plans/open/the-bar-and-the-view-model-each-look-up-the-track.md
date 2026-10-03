# The now-playing bar and the view model each look up the current track

Status: **Open**, small
Components: `Spotifly/Views/NowPlayingBarView.swift` (`currentTrackId`, `currentTrack`),
`Spotifly/ViewModels/PlaybackViewModel.swift` (`currentNowPlayingTrack`,
`toggleCurrentTrackFavorite`)
Found: 2026-10-03, in the reuse review of `plans/done/the-bars-duration-fallback-is-written-twice.md`

## Summary

The track the bar shows is found twice: the bar parses `currentTrackUri` and looks the id up in
the environment's store (`currentTrackId`, `currentTrack`), and the view model does the same in
`currentNowPlayingTrack`, for Control Center and the displayed length, through the store
attached to it; `toggleCurrentTrackFavorite` parses the uri a third time. They agree today, but
a change to which id counts, the logical track or a relinked one, has to be made in each.

## Solution

Proposed: the view model's `currentTrackId` and `currentTrack`, which the bar reads in place of
its own. The view model's store is attached by `LoggedInLifecycleModifier` before the first
`await` of the window's first task; a bar drawn before that has no track to show anyway.

## Verification

Live, a muted album start and a skip: the bar's title and artist, its heart's name and Control
Center's title name the same track, and follow the skip.
