# The now-playing bar and the view model each look up the current track

Status: **Done** (2026-10-03)
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

As proposed: the view model's `currentTrackId` and `currentTrack` are the one lookup. The bar
reads them for its title, artwork, artist and album links, heart and favorite checks;
Control Center, the displayed length and `toggleCurrentTrackFavorite` use them too.
`currentNowPlayingTrack` is gone, and the bar's own two properties.

## Verification

Live, a muted album start and two skips, read from outside through accessibility: the bar's
title and artist, its heart and Control Center's title named the same track each time ("Not Bad
for New Jersey", "Better Before", "Pearls", by Brian Fallon; the heart "Add to Favorites").
625 unit tests pass.
