# A seek on a mirrored track with no device active fails

Status: **Open**, seen once live
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`seek(positionMs:)`, `resume()`),
`Spotifly/ViewModels/PlaybackViewModel.swift` (`performSeek`)
Found: 2026-10-03, while doing the search field's focus fix

## Summary

Right after a launch, the bar shows the track Spotify last heard of, paused, mirrored "from no
active device". A click on the seek bar then says "Invalid state: No track loaded" in the bar,
and the position snaps back.

## Problem

Measured once on 2026-10-03 with the Debug build of main:

```
PlaybackViewModel] performSeek had no active device - running locally
PlaybackViewModel] performSeek failed: Invalid state: No track loaded
```

With no device active, the transport commands run locally. `LibrespotClient.resume()` knows that
case: nothing is loaded while the snapshot shows a track, so it takes the mirrored track over
(`takeOverState`, `continuePlayback`). `seek(positionMs:)` doesn't, and goes straight to the
audio pipeline, which has nothing loaded.

## Solution

Proposed: `seek` takes the mirrored track over as `resume` does, at the new position and paused,
so a later Play starts from where the user moved it. Whether Spotify's own clients keep a paused
track paused when the position moves, check against the web player first.

## Verification

- [ ] Launch with the last track paused and no device active; click the seek bar. The bar keeps
      the new position and shows no error; Play starts from there.
