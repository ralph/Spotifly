# A track this Mac lets go of jumps back to its last reported position

Status: **Open**, seen once with a faked failure
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirror`, `playbackFailed`,
`releasePlayback`), `Spotifly/SwiftLibrespot/Proto/TransferState.swift`
(`positionAsOfTimestamp`)
Found: 2026-10-03, verifying `plans/done/playback-view-model-mirrors-the-player.md`

## Summary

When this Mac stops playing over an error, the bar keeps the track, stopped where it was. Then the
cluster's answer to the release arrives with no active device, and the bar mirrors this Mac's own
last report from there: the position that report gave, without the time played since.

Seen with a throwaway that called `playbackFailed` 10.2 s into a track: the bar stopped at
10188 ms, and 34 ms later the mirror anchored it at 3894 ms, the position of the report this Mac
had sent 6.3 s earlier, when shuffle was switched on.

## Problem

`mirror(_:deviceActive:)` builds the state with `positionMs: remote.positionAsOfTimestamp` and
the report's timestamp. With no device active it says not playing, so the view model anchors
that raw position and does not run it on, though the report said playing and Spotify would
count on from its timestamp. For a device that has gone, that is right: it stopped at some
unknown moment. For this Mac's own release, it stopped now, and the client knows where.

The client reports to the cluster on changes only, so the gap is as long as the time since the
last change: minutes, into a track.

## Solution

Not decided. Either:
- `releasePlayback` reports where playback stopped, paused, before it lets go, so the cluster's
  last state is current; or
- the mirror leaves a track this Mac just released at the position it had, when the cluster
  names it with this device's own last report.

The first is what librespot does on stop, if it does: check first.

## Verification

The throwaway `LibrespotClient.debugFail()` (calls `playbackFailed`), a few seconds after a
report: the bar's position before and after the cluster's answer, from a sampler.
