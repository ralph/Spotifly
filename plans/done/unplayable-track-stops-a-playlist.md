# An unplayable track stops a playlist, and says nothing

Status: **Done** 2026-09-29 (#57). Built, unit-tested and lint-clean, and the four live checks
under Verification passed on the final build (`c2760e3`) the same day.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`handleEndOfTrack`,
`autoAdvance`, `loadAndPlay`, `startTrack`, `playbackFailed`),
`Spotifly/SwiftLibrespot/Public/AutoAdvance.swift`,
`Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`playTrack`, `preparedTrack`, `fileToPlay`),
`Spotifly/SwiftLibrespot/Core/Errors.swift` (`trackUnavailable`),
`Spotifly/SpotifyPlayer.swift` (`PlaybackInterruption`), `Spotifly/Store/PlayerModel.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift` (`observePlayer`),
`Spotifly/Views/NowPlayingBarView.swift` (`trackInfo`)
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

**Now:** auto-advance goes past a track Spotify withholds and the bar says "Skipped, not
available: “…”". Any other load error still stops playback, and the bar says why. A
failed load lets go of the active role, so other devices stop showing this Mac as playing.
What is left is in `plans/open/unplayable-tracks-look-playable.md`.

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

**What the metadata says.** `/metadata/4` for that track (as JSON, from the web player's tab)
carries `restriction: [{ countries_allowed: "" }]`, allowed in *no* country, and no
`alternative`. A playable track carries no `restriction`. "I Took A Pill In Ibiza" carries the
same empty restriction *and* an alternative, which is why it plays: its files come from the
substitute. So "not available in your country" would say more than the data does. The track
is withheld everywhere.

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

- [x] In a Debug build, play the three librespot-era ids one at a time:
      `SPOTIFLY_DEBUG_AUTOPLAY=spotify:track:4kVIImqwUPakCujdyQ3YP2`, then
      `4771ccpHnvLwaEacV0dh9E` and `2X7Bo34Z1c375Jo6JQaVnL`. Record the `AudioPipeline` line
      for each: it plays, `No Ogg Vorbis file available`, an audio key error, or a CDN error.
      **Read from `/metadata/4` on 2026-09-29 instead of played.** They are chapters 1 to 3 of
      the audiobook "Mein Lotta-Leben. Alles voller Kaninchen", each with
      `restriction { countries_allowed: "" }` and no alternative, exactly as "Girlfriend". So
      they take the same path, and the live check under Verification covers it.
- [x] Find a known unplayable track, in case all three play. Found 2026-09-29:
      `spotify:track:6PpbRUIbMyUbJkWHS3eQ8j`, `COUNTRY_RESTRICTED` in DE. See *Observed on
      2026-09-29*.

**Outcome:** the `LibrespotError` that a genuinely unplayable track produces. Step 2 keys on
that error. For a country-restricted track it is
`trackNotFound("No Ogg Vorbis file available")`, and as above, the case alone does not
identify it. Step 2 needs to tell that one apart from the non-200 `trackNotFound`s, with a
dedicated error for "no playable file", for example.

**Done:** `LibrespotError.trackUnavailable(name:)`, thrown by `AudioPipeline.fileToPlay` when
the track lists no file at all, its own or a substitute's. Files that are all in formats the
player does not decode still throw `trackNotFound("No Ogg Vorbis file available")`. That is not
Spotify withholding the track, and it has not been seen.

### Step 2: skip on auto-advance, stop on anything else

- [x] In `handleEndOfTrack`, if the load fails with Step 1's error, and only that one, not
      any `trackNotFound`, advance again instead of stopping. Any other error, such as the network or a key timeout, stops playback as it
      does today. A skip must mean the track cannot play. It must never mean the network
      blinked, or a short outage would skip a playlist's worth of playable tracks.
- [x] The queue bounds the loop: it ends at the context's end, where `rewindContext` takes
      over. A playlist of unplayable tracks costs one metadata request per track. Say so in
      the commit rather than adding a cap for it.
      **Not quite, so there is a cap.** With repeat-context on, `advance()` wraps, and a context
      of nothing but unavailable tracks would skip forever. `AutoAdvance.run` tries at most as
      many tracks as the queue holds, then stops with the last error. Each skip costs the
      metadata request and the extended-metadata one.
- [x] Leave Next and a remote `skip_next` as they are. They stop, and #72 shows their error.
      Skipping is only for auto-advance, where nobody pressed anything.
- [x] Found while building it: a load that failed *after a newer one started* still threw its
      own error, not a cancellation. `loadAndPlay` then cleared the newer load's state, and a
      skip would have moved the queue under it. `AudioPipeline.playTrack` already had a load
      generation, checked only after a successful fetch; it now checks it after a failed one
      too and throws `CancellationError`. That covers a `stop()` as well, such as another
      device taking over while a skip loads.
- [x] Found in code review: the attempts were counted after the end of the track had taken
      the next one off the user queue, so a run that started there gave up one track short.
      On a repeating context whose one playable track had just ended, it stopped instead of
      wrapping round to it. The track the run starts from now counts when it came off the user
      queue.
- [x] Found in code review: extended-metadata drops formats `AudioFormat` does not name, so a
      track with nothing but those read as having no files at all, and was skipped as
      unavailable. They are kept, as `.unknown`, when they are all there is, so such a track
      stops with `trackNotFound` as intended.
- [x] Found in review: the fetch-ahead of an unavailable next track failed, and
      `preparedTrack` swallowed that and fetched it again at the end of the track. It now
      rethrows `trackUnavailable`, which asking again cannot change.

The rule is `AutoAdvance.run`, a static function over the client's `PlaybackQueue` and two
closures, so `AutoAdvanceTests` checks it against a real queue
without a session: an unavailable track is skipped; a `URLError`, a `trackNotFound` or an audio
key failure stops; repeat over nothing but unavailable tracks stops after one pass; and a
superseded load neither skips nor stops.

### Step 3: say so in the bar

- [x] The client cannot hand the UI an error it hit on its own. Add one field to
      `PlayerSnapshot` for the last auto-advance that failed or was skipped: the uri and the
      error. `PlaybackViewModel` puts it into `errorMessage`, which the bar already shows for
      five seconds. New localization keys go in `de`, `en` and `fr`.
      **Done** as `PlayerSnapshot.interruption`, a `PlaybackInterruption`: the message and a
      sequence number, counted on the snapshot as `clusterRevision` is. The number
      is needed because `PlayerModel` passes on changes only, so the same skip twice in a row
      would otherwise be told once. It stays in the snapshot until the next one, so the
      newest-only stream cannot drop it. The keys are `error.track_unavailable %@` and
      `playback.skipped_unavailable %@`.
- [x] A stop caused by an error that is not skipped shows the same way. That is the other half
      of "says nothing". So does a failed rewind to the context's first track, and an audio
      pipeline error mid-track, which cleared the playback just as silently.
- [x] Report the stop to Connect. After a failed load, `clearLocalState` should also report
      the cleared state to the cluster, so a phone stops showing the Mac as playing a track it
      never started. This applies to a user-started play too.
      **Done** in `playbackFailed` rather than `clearLocalState`, which a stand-down and a
      teardown also call. It is the one place a failure ends playback: it clears the local
      state, gives up the active role and reports, as a failed transfer already did, and
      publishes the interruption. `loadAndPlay`, auto-advance's stop and a pipeline error all
      go through it. `rewindContext` explains why a report with no player state is not enough
      while the device stays active. Auto-advance tries tracks with `startTrack`, which does
      none of this, and fails once at the end, so other devices do not see the Mac stop and
      start again between two tracks. A failed transfer still reports twice, once from the load
      and once from `takeOver`, whose own release is needed for a context that fails to
      resolve.
- [x] Name the real cause. "Track not found: No Ogg Vorbis file available" reads like a bug for
      a track Spotify has simply withheld. "Not available in your country" is accurate for
      `COUNTRY_RESTRICTED`.
      **Done** as "Not available on Spotify: “Girlfriend (feat. Dâm-Funk)”", and "Skipped, not
      available: “…”" for a skip. It does not say "in your country": the metadata allows the
      track in no country (see *What the metadata says*). A play started from the app, Next or
      Previous shows the same message through #72. The reason comes first because the bar cuts
      off what does not fit. The first wording, name first, showed only
      "Übersprungen: „Girlfriend (feat. Dâm-Funk)“ ist a…" in the first live run.
- [x] Found in that run: the bar showed one line of the error, although it allows two, and the
      tooltip holding the full text rarely appeared. The row offered the label one line's
      height, so it now takes its own (`fixedSize(horizontal: false, vertical: true)`), checked
      by rendering the row with `ImageRenderer`. The tooltip waited for the pointer to rest,
      and by then the error had usually cleared itself after its five seconds. Pointing at the
      error now keeps it up and shows the full text in a popover at once.

### Not in this plan

These are in `plans/open/unplayable-tracks-look-playable.md`:

- Greying unplayable tracks in lists and in the queue, from the `playability` pathfinder
  already sends.
- A rewind to a context whose first track is unavailable stops there, rather than finding the
  first one that plays.
- A track whose files are all in formats the player does not decode stops auto-advance. Not
  seen.

## Verification

- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare with the exit
      code checked. 2026-09-29: build succeeded, all tests passed, lint exit 0.
- [x] Live: a playlist of three tracks, playable, Step 1's unplayable one, playable. From a
      DE account, `6PpbRUIbMyUbJkWHS3eQ8j` is one. Seek near
      the end of the first. The second is skipped and the bar says so, and the third plays.
      Paste the `LibrespotClient` and `AudioPipeline` lines.
      **2026-09-29**, with "Spotifly test: Girlfriend" (`0qNtVGwd9fPrEUdMTygw8y`: "Gold Lion",
      "Girlfriend", "The Diamond Church Street Choir"). Seen in the bar, not in the log: "The
      Diamond Church Street Choir" playing as 3/3, under
      "Übersprungen: „Girlfriend (feat. Dâm-Funk)“ ist a…", the first wording, cut off. The
      log lines were not kept. **Re-run on the final build (`c2760e3`) the same day: passed**,
      with the message in its final wording and the popover on pointing at it.
- [x] Live: the same playlist with Wi-Fi turned off in the first ten seconds of the first
      track, before the fetch-ahead runs. At the end of the track, playback stops and the bar
      shows the error. Nothing is skipped. **Passed** on `c2760e3`, 2026-09-29.
- [x] A phone watching the Mac shows the third track as playing, not the second. **Passed**
      on `c2760e3`, 2026-09-29.
- [x] Live: double-click `6PpbRUIbMyUbJkWHS3eQ8j` in Liked Songs. The bar names the reason,
      and a phone or the web player stops showing the Mac as playing it. **Passed** on
      `c2760e3`, 2026-09-29.
