# Shuffle and Add to Queue on a mirrored track with no device active

Status: **Open**, from a review; unmeasured
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`setShuffle`, `addToQueue`,
`continuePlayback`), `Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-10-03, in the review of `plans/done/seek-on-a-mirrored-track-fails.md`

## Summary

With no device active, the bar mirrors the track Spotify last heard of, and nothing is loaded
here. Play, a seek, Previous, Next and a queue row now take that track over
(`LibrespotClient.takeOverMirror`). Shuffle and Add to Queue still act on the empty local queue.

## Problem

Read from the code, not yet seen live:

- **Shuffle** shuffles the empty or stale local queue and publishes it over the mirror, so the
  Queue section empties until the next cluster push. The Shuffle button doesn't change, since
  `publishPlaybackStateRefresh` returns while nothing is loaded. A later takeover sets shuffle from
  the mirror again, so the toggle is lost.
- **Add to Queue** puts the track into the local queue, which replaces the mirror on screen until
  the next push. Any takeover then replaces the local queue with the mirror's queued tracks
  (`continuePlayback`'s `replaceUserQueue(with:)`), so the track never plays.

## Solution

Measure the web player first, in the same state: whether Shuffle and Add to Queue take the track
over, and whether they start it. Then take the mirror over before acting, as the transport
commands do, or keep the toggle and the queued track for the takeover to carry. The second needs
care: a plain append could bring back tracks left from an earlier session here.

## Verification

- [ ] With no device active, Shuffle changes the button and the Queue section keeps its rows.
- [ ] With no device active, a track added to the queue plays after the current one, once
      playback starts.
