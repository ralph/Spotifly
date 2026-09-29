# An unplayable track stops a playlist, and says nothing

Status: **Open**, priority 1. Planned, not started (#57, branch `plan/unavailable-tracks`).
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`handleEndOfTrack`,
`clearLocalState`), `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`prepare`),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`playableFiles`, `getTrackMetadata`,
`getAudioFiles`)
Found: 2026-08-14, in `../seek-after.log`, under librespot. Re-read against the Swift stack
on 2026-09-29, and seen the same day with a country-restricted track in Liked Songs.

## Summary

When auto-advance reaches a track that cannot play, playback stops there. The bar goes
empty, the rest of the album or playlist never plays, and nothing says why. The auto-advance
half is read from the code and has not been observed. Under librespot the same tracks drained
the whole queue in half a second instead. That symptom went with librespot; the silence did
not.

A *user-started* play of an unplayable track was observed on 2026-09-29: the bar shows an
error that names the wrong cause, and Spotify Connect goes on reporting the track as playing.

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
  For a country-restricted track, Spotify lists no files at all: see *Observed on 2026-09-29*.
- **`trackNotFound` does not mean "cannot play" on its own.** `SPClient.getTrackMetadata` and
  `SPClient.getAudioFiles` throw `trackNotFound` for *any* non-200 answer, a 5xx or a 429
  included. Only the `"No Ogg Vorbis file available"` case from `prepare` says the track has
  nothing to play.
- **Auto-advance swallows the failure and stops.** `LibrespotClient.handleEndOfTrack` runs
  `try? await loadAndPlay(upcoming)`, and `loadAndPlay` clears the local state when the load
  fails. #72 shows errors from plays the view model starts. Auto-advance is started by the
  client, so its errors never reach the view model.
- **A failed load leaves Connect claiming the track plays.** `loadAndPlay` publishes an
  optimistic "playing" state and reports it to the cluster before the load. On failure,
  `clearLocalState` clears the UI's playback but never calls `reportPlaybackToCluster()`, so
  every later PutState repeats "playing 0ms". Read from the code, and it matches the log
  below.

### Observed on 2026-09-29

Double-clicking "Girlfriend (feat. Dâm-Funk)" by Christine and the Queens
(`spotify:track:6PpbRUIbMyUbJkWHS3eQ8j`) in the account's Liked Songs, in DE. The row and the
song matched; the track cannot play here. Pathfinder says so before anything is
loaded. The Liked Songs `fetchPlaylistContents` item carries

```
"playability": { "playable": false, "reason": "COUNTRY_RESTRICTED" }
```

The player found no files and no playable alternative:

```
08:17:57.463 SPClient] [GET] …/metadata/4/track/e0624580e17b49bab335775ea6fe1593
08:17:57.464 SPClient] Parsed track: Girlfriend (feat. Dâm-Funk), duration=201073ms, files=0
08:17:57.496 SPClient] Extended metadata: 1 array(s), 1 data(s), yielded 0 file(s)
08:17:57.496 AudioPipeline] Track 'Girlfriend (feat. Dâm-Funk)': 0 file(s), 201073ms
08:17:58.546 SpircController] PutState newDevice active=true: playing 0ms@1790669877461
08:18:28.966 SpircController] PutState newDevice active=true: playing 0ms@1790669877461
```

The bar showed "Track not found: No Ogg Vorbis file available" (#72) beside the track, with
"1/51". The web player on another machine showed the Mac playing it. It is not a relinking
case: a market substitute would have been returned in its place, as "The Letter" is.

**It is not rare.** That day, 221 of the account's 609 Liked Songs were `COUNTRY_RESTRICTED`,
all with the same reason, from three albums. Two albums were bulk-saved in 2019 and made up
contiguous runs of 106 and 114 rows. With auto-advance stopping at the first unplayable
track, Liked Songs could not play past row 178. Those two albums were un-favorited the same
day, so "Girlfriend" is the one left in that library to test with.

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

- [ ] In a Debug build, play the three librespot-era ids one at a time:
      `SPOTIFLY_DEBUG_AUTOPLAY=spotify:track:4kVIImqwUPakCujdyQ3YP2`, then
      `4771ccpHnvLwaEacV0dh9E` and `2X7Bo34Z1c375Jo6JQaVnL`. Record the `AudioPipeline` line
      for each: it plays, `No Ogg Vorbis file available`, an audio key error, or a CDN error.
- [x] Find a known unplayable track, in case all three play. Found 2026-09-29:
      `spotify:track:6PpbRUIbMyUbJkWHS3eQ8j`, `COUNTRY_RESTRICTED` in DE. See *Observed on
      2026-09-29*.

**Outcome:** the `LibrespotError` that a genuinely unplayable track produces. Step 2 keys on
that error. For a country-restricted track it is
`trackNotFound("No Ogg Vorbis file available")`, and as above, the case alone does not
identify it. Step 2 needs to tell that one apart from the non-200 `trackNotFound`s, with a
dedicated error for "no playable file", for example.

### Step 2: skip on auto-advance, stop on anything else

- [ ] In `handleEndOfTrack`, if the load fails with Step 1's error, and only that one, not
      any `trackNotFound`, advance again instead of stopping. Any other error, such as the network or a key timeout, stops playback as it
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
- [ ] Report the stop to Connect. After a failed load, `clearLocalState` should also report
      the cleared state to the cluster, so a phone stops showing the Mac as playing a track it
      never started. This applies to a user-started play too.
- [ ] Name the real cause. "Track not found: No Ogg Vorbis file available" reads like a bug for
      a track Spotify has simply withheld. "Not available in your country" is accurate for
      `COUNTRY_RESTRICTED`.

### Not in this plan

- **Greying unplayable tracks in lists and in the queue.** That needs per-track availability
  before anything plays. The responses carry it and the entities do not. Every playlist and
  Liked Songs item has `itemV2.data.playability { playable, reason }` (measured 2026-09-29), and
  `PathfinderPlaylistTrack` does not decode it. Album, search and spclient answers are
  unchecked. It is a feature of its own, but it is not blocked on data. Its reason would also
  make Step 3's message precise wherever the track came from a list.

## Verification

- [ ] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare with the exit
      code checked.
- [ ] Live: a playlist of three tracks, playable, Step 1's unplayable one, playable. From a
      DE account, `6PpbRUIbMyUbJkWHS3eQ8j` is one. Seek near
      the end of the first. The second is skipped and the bar says so, and the third plays.
      Paste the `LibrespotClient` and `AudioPipeline` lines.
- [ ] Live: the same playlist with Wi-Fi turned off in the first ten seconds of the first
      track, before the fetch-ahead runs. At the end of the track, playback stops and the bar
      shows the error. Nothing is skipped.
- [ ] A phone watching the Mac shows the third track as playing, not the second.
- [ ] Live: double-click `6PpbRUIbMyUbJkWHS3eQ8j` in Liked Songs. The bar names the reason,
      and a phone or the web player stops showing the Mac as playing it.
