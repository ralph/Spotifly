# An unplayable track looks like any other until it is played

Status: **Done** 2026-09-29 (#87). The eight checks in the PR passed in the app the same day, on `b0344a6`.
What this left is in `plans/done/unplayable-tracks-found-by-loading.md`.
Components: `Spotifly/PartnerAPI/PathfinderSearch.swift` (`PathfinderPlayability`),
`Spotifly/PartnerAPI/PathfinderPlaylist.swift`, `Spotifly/PartnerAPI/PathfinderAlbum.swift`,
`Spotifly/PartnerAPI/PathfinderEntities.swift`, `Spotifly/Store/Entities.swift` (`Track`,
`Playability`), `Spotifly/Store/AppStore.swift` (`upsertTracks`, `unplayableTrackUris`),
`Spotifly/Views/TrackRow.swift`, `Spotifly/Views/Components/TrackCard.swift`,
`Spotifly/Views/Components/TrackContextMenu.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift` (`playRadio`),
`Spotifly/SwiftLibrespot/Public/PlaybackQueue+Unplayable.swift`,
`Spotifly/SwiftLibrespot/Public/AutoAdvance.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`setUnplayable`, `knownUnplayable`)
Found: 2026-09-29, with 221 of one account's 609 Liked Songs `COUNTRY_RESTRICTED`; see
`plans/done/unplayable-track-stops-a-playlist.md`

## Summary

The app learns that a track cannot play only by trying to load it. Since #57, auto-advance goes
past such a track and the now-playing bar says so. But every list and the queue still show it
like any other track. Double-clicking it, or pressing Next onto it, gets an error instead of
music. Spotify's own clients grey these rows out, and the data to do the same already arrives.

## Problem

### What the app shows

- **Lists.** A withheld track is an ordinary row in a playlist, Liked Songs, an album, search
  or an artist's top tracks. Nothing marks it before the double-click fails.
- **The queue.** The upcoming list shows it too. Auto-advance now skips it, but only when it
  gets there, and the queue said it would play.
- **Next and Previous** onto one stop with "Not available on Spotify: “…”". #57 left them
  that way on purpose. Nobody pressed them expecting a skip. With the availability known up
  front, they could step over it the way Spotify's clients do.

### What the data carries

- **Playlists and Liked Songs:** every `fetchPlaylist`/`fetchPlaylistContents` item has
  `itemV2.data.playability { playable, reason }`, for example
  `{ "playable": false, "reason": "COUNTRY_RESTRICTED" }`. Measured 2026-09-29.
  `PathfinderPlaylistTrack` does not decode it.
- **Albums, search, artist top tracks, home:** checked 2026-09-29 with a probe from the test
  host. `getAlbum` has it on `tracksV2.items[].track`, and gave the withheld track
  `{ "playable": false }` with no reason. Search has it on `tracksV2.items[].item.data`, as
  `PLAYABLE` for every result: the withheld track was not among them. The artist overview and
  home have it on releases, albums and playlists, not on tracks, and the app lists no tracks
  from either.
- **spclient `/metadata/4`:** a withheld track has `restriction { countries_allowed: "" }` and
  no `alternative`. A relinked one has the same restriction with an alternative, and plays. So
  the restriction alone does not mean unplayable. `Track(spclient:id:)` reads neither field.

### What else #57 left

All read from the code in review; none has been observed.

- **Rewinding to an unavailable first track.** When the queue ends, `rewindContext` loads the
  context's first track paused. If that one is withheld, playback stops with the message
  rather than rewinding to the first track that plays.
- **Files the player cannot decode.** A track whose files are all MP3, AAC or FLAC throws
  `trackNotFound("No Ogg Vorbis file available")`. That is not the skipped error, so
  auto-advance stops there. Spotify has not been seen to serve such a track to a Premium
  account.
- **The skip waits for the end of the track.** The fetch-ahead learns 10 to 30 seconds early
  that the next track is withheld, but nothing acts on it: the track after it is not fetched
  ahead, and the change of track loads it cold, with a gap, where it could have been
  gapless. The pipeline could report the failed fetch-ahead, so the client moves "next" past
  it and publishes the skip then.
- **A run of unavailable tracks costs two requests each, with no cap.** `AutoAdvance.run`
  tries as many tracks as the queue holds, and each costs `/metadata/4` and extended-metadata
  in turn. A playlist of 500 withheld tracks takes about 1,000 requests before it stops.
  Knowing playability up front would let auto-advance step over them without loading any.
  Without that, a cap on skips in a row would bound it.
- **Each attempt shows the skipped track, and reports it.** `startTrack` publishes an
  optimistic "playing" state for every track it tries, and the pipeline's `.loading` event
  reports it to the cluster. So the bar and other devices show the withheld track for as
  long as its metadata requests take. The bar also updates the Now Playing info, and fetches
  the cover if it differs.
- **A failed transfer reports twice.** `loadAndPlay` gives up playback through
  `playbackFailed`, and `takeOver`'s catch releases again. That second release is needed for a
  context that fails to resolve, before any load. The cost is one extra PutState.

## Solution

1. [x] **Decoded.** `PathfinderPlayability` on the playlist, album and search track shapes,
       into `Track.playability`: `.playable`, or `.unplayable(reason:)`. It is `.playable`
       unless the answer says otherwise, so spclient's metadata, which does not say, changes
       nothing. Every answer that replaces a track in the store says; spclient only fills in
       tracks the store lacks.
2. [x] **Greyed out, with the reason.** `TrackRow` dims an unplayable row as it dims a queue
       entry it cannot name, and its tooltip says "Not available in your country: “…”" for
       `COUNTRY_RESTRICTED` and "Not available on Spotify: “…”" otherwise. That covers every
       list that uses the row: playlists, Liked Songs, albums, search's track list and the
       queue. Search's track cards are dimmed the same way.
3. [x] **Decided: it starts nothing, and playback steps over it without loading it.**
       - **A double-click** plays nothing and says why in the bar. Neither does radio from
         it, wherever it is started: search's double-click and cards, and the menu, where
         Play Next and Start Radio are disabled. `PlaybackViewModel.playRadio` checks the
         store, so every way in says the same.
       - **Next, Previous, auto-advance and the fetch-ahead** step over a known one without
         loading it, and without a "Skipped" message, since its row is greyed.
       - **Play on an album or playlist** starts at the first track that plays, and so does the
         rewind at the end of the context.
       - **How playback knows.** The context resolver's answer has no playability, measured on
         the same playlist: its tracks carry `uid`, `uri` and `metadata`, whose keys are
         `added_at`, `added_by_username` and `highlight_id`. So the app tells it:
         `AppStore.upsertTracks` keeps `unplayableTrackUris`, adding and removing as tracks
         arrive, and `LoggedInLifecycleModifier` passes each change to
         `LibrespotClient.setUnplayable`. The client also keeps the tracks that failed to load
         as unavailable, so a second pass round a context the app never listed loads none of
         them twice. Both are cleared at logout.
       - The stepping is the queue's, in `PlaybackQueue+Unplayable.swift` (`stepOver`, `move`,
         `back`, `upcomingPlayable`), built on its own moves and tested against a real queue.
         Previous steps back only when something in the history plays; otherwise it restarts
         the current track and leaves the queue where it was (found in review). It is a
         file of its own because other open PRs rework `PlaybackQueue.swift`. Each track
         stepped over goes into the history, as a skipped one has since #57.

### What else #57 left, now

- **Rewinding to an unavailable first track:** done, for a known one.
- **The skip waits for the end of the track, and a run costs two requests each:** done for
  known ones. The fetch-ahead names the next track that plays, so the change stays gapless,
  and a run of them costs nothing. Tracks the app has not listed are still found out by
  loading them; see the new plan.
- **Each attempt shows the skipped track, and reports it:** gone for known ones, unchanged for
  the others.
- **Files the player cannot decode, and a failed transfer reporting twice:** unchanged, and
  carried over to the new plan.

## Verification

- [x] The shapes, measured 2026-09-29 with a throwaway probe from the test host, for "Girlfriend
      (feat. Dâm-Funk)" (`COUNTRY_RESTRICTED` in Germany) and its album, its artist, a search
      and home. The context resolver was probed on the same playlist.
- [x] Unit tests (`PlayabilityTests`, `AutoAdvanceTests`), 9 new, 399 in all:
      - the playlist, album and search shapes;
      - the message by reason;
      - a known track stepped over without a load or a word, also after one that failed to
        load;
      - a queue known to be all unplayable ends after one pass under repeat;
      - Previous steps back over known ones, and leaves the queue alone when none plays.
      Lint exits 0.
- [x] In the app, with the playlist "Spotifly test: Girlfriend": the row is greyed with the
      tooltip, a double-click says why, and Play, Next, Previous and auto-advance pass over it.
      **Passed**, all eight steps in #87, on `b0344a6`, 2026-09-29: the tooltip and the
      double-click in German, the menu items disabled, a gapless change with no request for
      the withheld track, Next and Previous, the queue, the album without a reason, Liked
      Songs, and Play on the playlist with "Girlfriend" moved to the top.
