# An unplayable track stops a playlist, and says nothing

Status: **Open**, priority 1. The plan is on #57, branch `plan/unavailable-tracks`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`handleEndOfTrack`),
`Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`prepare`),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`playableFiles`)
Found: 2026-08-14, in `../seek-after.log`, under librespot. Re-read against the Swift stack
on 2026-09-29.

## Summary

When auto-advance reaches a track that cannot play, playback stops there. The bar goes
empty, the rest of the album or playlist never plays, and nothing says why. This is read from
the code and has not been observed. Under librespot the same tracks drained the whole queue in
half a second instead. That symptom went with librespot; the silence did not.

## Problem

### What the Swift stack does

- **A relinked track plays.** A market substitute has no files of its own; its playable copy
  sits under `Track.alternative`, and `SPClient.playableFiles` uses the alternative's files.
  That was librespot's "no alternatives found" case, and it may be all the three ids below
  ever were.
- **A track without a playable file fails its load.** `AudioPipeline.prepare` throws
  `LibrespotError.trackNotFound("No Ogg Vorbis file available")`. So does a non-track uri,
  such as an episode in a playlist, from `trackGid` (`"not a track uri"`). A restricted track
  that still lists files would fail later, at the audio key (`audioKeyError`) or the CDN.
  Which of these Spotify does is not known.
- **Auto-advance swallows the failure and stops.** `LibrespotClient.handleEndOfTrack` runs
  `try? await loadAndPlay(upcoming)`, and `loadAndPlay` clears the local state when the load
  fails. #72 shows errors from plays the view model starts. Auto-advance is started by the
  client, so its errors never reach the view model.

### Found under librespot

A playlist started on 2026-08-14 played its first track. librespot's availability check then
refused every following one and skipped each in a fraction of a second, so playback was dead
while the app still looked like it was playing:

```
07:22:11.203 ERROR librespot_playback::player] Track should be available, but no alternatives found.
07:22:11.203 WARN  librespot_playback::player] spotify:track:<4kVIImqwUPakCujdyQ3YP2> is not available
07:22:11.203 ERROR librespot_playback::player] Skipping to next track, unable to load track <SpotifyUri("…")>: ()
07:22:11.323 ERROR librespot_playback::player] … <4771ccpHnvLwaEacV0dh9E> is not available
07:22:11.363 ERROR librespot_playback::player] … <2X7Bo34Z1c375Jo6JQaVnL> is not available
```

A later run on a different playlist had two of the same warnings and played through, so it
was neither every playlist nor every unavailable track. The three ids are the known test
cases.

## Solution

The plan is on #57. It finds out which error a genuinely unplayable track produces, skips on
that error only and only on auto-advance, so a network error still stops playback, and shows
the reason in the now-playing bar.

## Verification

Defined with the plan on #57.
