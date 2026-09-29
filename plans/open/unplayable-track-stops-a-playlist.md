# An unplayable track stops a playlist, and says nothing

Status: **Open**, priority 1. Planned, not started (#57, branch `plan/unavailable-tracks`).
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

Skip an unplayable track on auto-advance, and say so in the now-playing bar. Only an error
that means the track cannot play leads to a skip, so a network error still stops playback.

### Step 1: find out what an unplayable track produces

- [ ] In a Debug build, play the three ids one at a time:
      `SPOTIFLY_DEBUG_AUTOPLAY=spotify:track:4kVIImqwUPakCujdyQ3YP2`, then
      `4771ccpHnvLwaEacV0dh9E` and `2X7Bo34Z1c375Jo6JQaVnL`. Record the `AudioPipeline` line
      for each: it plays, `No Ogg Vorbis file available`, an audio key error, or a CDN error.
- [ ] If all three play, librespot was the whole cause, and there is no known unplayable
      track to test with. Find one before Step 2: the web client greys them out in a
      playlist. Otherwise Step 2 gets built against a guess.

**Outcome:** the `LibrespotError` that a genuinely unplayable track produces. Step 2 keys on
that error.

### Step 2: skip on auto-advance, stop on anything else

- [ ] In `handleEndOfTrack`, if the load fails with Step 1's error, advance again instead of
      stopping. Any other error, such as the network or a key timeout, stops playback as it
      does today. A skip must mean the track cannot play. It must never mean the network
      blinked, or a short outage would skip a playlist's worth of playable tracks.
- [ ] The queue bounds the loop: it ends at the context's end, where `rewindContext` takes
      over. A playlist of unplayable tracks costs one metadata request per track. Say so in
      the commit rather than adding a cap for it.
- [ ] Leave Next and a remote `skip_next` as they are. They stop, and #72 shows their error.
      Skipping is only for auto-advance, where nobody pressed anything.

### Step 3: say so in the bar

- [ ] The client cannot hand the UI an error it hit on its own. Add one field to
      `PlayerSnapshot` for the last auto-advance that failed or was skipped: the uri and the
      error. `PlaybackViewModel` puts it into `errorMessage`, which the bar already shows for
      five seconds. New localization keys go in `de`, `en` and `fr`.
- [ ] A stop caused by an error that is not skipped shows the same way. That is the other half
      of "says nothing".

### Not in this plan

- **Greying unplayable tracks in lists and in the queue.** That needs per-track availability
  before anything plays, and the entities do not carry it. It is a feature of its own.

## Verification

- [ ] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare with the exit
      code checked.
- [ ] Live: a playlist of three tracks, playable, Step 1's unplayable one, playable. Seek near
      the end of the first. The second is skipped and the bar says so, and the third plays.
      Paste the `LibrespotClient` and `AudioPipeline` lines.
- [ ] Live: the same playlist with Wi-Fi turned off in the first ten seconds of the first
      track, before the fetch-ahead runs. At the end of the track, playback stops and the bar
      shows the error. Nothing is skipped.
- [ ] A phone watching the Mac shows the third track as playing, not the second.
