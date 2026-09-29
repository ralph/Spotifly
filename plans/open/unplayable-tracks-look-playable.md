# An unplayable track looks like any other until it is played

Status: **Open**, not planned. Recorded 2026-09-29 while landing #57.
Components: `Spotifly/PartnerAPI/PathfinderPlaylist.swift` (`PathfinderPlaylistTrack`),
`Spotifly/PartnerAPI/PathfinderEntities.swift`, `Spotifly/Store/Entities.swift` (`Track`),
`Spotifly/Views/TrackRow.swift`, `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`
(`rewindContext`, `executeRemoteCommand`)
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
- **Albums, search, artist top tracks, home:** not checked. The documents may select
  `playability` too.
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

Not planned yet. A likely shape:

1. Decode `playability` into `Track` (`isPlayable`, and the reason) from every response that
   carries it, starting with the playlist items. Check the album and search documents first.
2. Grey out unplayable rows, as Spotify's clients do, and say why on hover or in the context
   menu. The reason also lets the message say "in your country" where that is what Spotify
   reports.
3. Decide whether a double-click, Next and Previous step over a track known to be unplayable,
   rather than failing on it. So could auto-advance, without loading it. The queue is built
   from uris, so this needs a lookup in the store.

## Verification

None yet.
