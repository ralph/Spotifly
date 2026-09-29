# An album, artist or playlist union of an unknown kind reads as "no data"

Status: **Done** 2026-09-29. Built and unit-tested; not yet seen in the running app; see
Verification.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`album(id:)`, `artistUnion`, `playlistPage`),
`Spotifly/Views/AlbumDetailView.swift`, `Spotifly/Views/ArtistDetailView.swift`,
`Spotifly/Views/PlaylistDetailView.swift`, `Spotifly/Views/Components/InlineLoadError.swift`,
`Spotifly/Store/Services/AlbumService.swift`, `ArtistService.swift`, `PlaylistService.swift`,
`Spotifly/Store/Services/InFlightRequests.swift` (`NotFoundMemory`, `isRetryable`)
Found: 2026-09-29, in the reviews of `plans/done/playlist-not-found-answers-500.md`

## Summary

Three guards now turn a `NotFound` union into "Spotify can't find this …" with no retry, one per
kind. Every other `__typename` still decodes as a success with nil fields, and the service then
throws "Spotify returned no data", with a Try again. The views each keep a `canRetry` flag beside
their error message by hand.

## Problem

- **One bad name is rejected, instead of the good one accepted.** The home page
  (`PathfinderHome.successTypename`) and the mutations (`PathfinderMutationResult.failure(unless:)`)
  accept only their success name. The album, artist and playlist unions single out `NotFound`.
  - Measured 2026-09-29: a malformed playlist id answers HTTP 200 with `GenericError`, "Failed to
    fetch playlist for uri …, status code: 400 BAD_REQUEST". That reads as "no data", and Try
    again repeats the 400. The app only opens ids Spotify gave it, so this is rare.
  - The guard pair, nil union then `NotFound`, is written out three times.
- **The retry flag lives beside the message.** Album, artist and playlist views each keep
  `errorMessage` and `canRetry` as two `@State`s. Other writers set `errorMessage` without
  `canRetry` (the playlist's delete, unfollow, rename and reorder), so the flag can describe an
  earlier error. Harmless today: after a `NotFound`, nothing on the page can fail again.
- **A page Spotify cannot find is asked for on every visit.** Nothing records the miss, and
  `ensure…Loaded` checks only whether the entity is loaded. Each rebuild of the view asks again
  and gets the same answer. `TrackService.unavailableTrackIds` already remembers such misses for
  tracks.

## Solution

The plan's three parts, in one change, since each spans albums, artists and playlists.

### 1. One check, naming the failures

The plan suggested switching on the success name, as the home page and the mutations do, and
warned to check the names first: "a kind nobody has seen, such as a pre-release album, would
become an error". Checked in the web player's bundle on 2026-09-29, reading which names its code
compares `__typename` against. Besides `Album`, `Artist` and `Playlist`, it switches on
`PreRelease` (and a `PreReleaseResponseWrapper`), `PseudoPlaylist`, `RestrictedContent` and
`UnknownType`. An allow-list of three would have turned pages Spotify serves into errors, and
`PseudoPlaylist` may well be what some playlist-shaped pages are.

So `PartnerAPI.entity(_:kind:)` names the failures instead:

- `NotFound` throws `notFound(kind)`, as before, and is not retried;
- `GenericError` throws the new `entityFailed(kind)`, "Spotify could not load this
  album." (artist, playlist; de and fr too), which stays retryable, with Spotify's own message in
  the log;
- anything else decodes as before, and a kind that carries no entity is still "Spotify returned
  no data" in the service.

The review of the change traced its reach. `entity` also covers the discography, the later
pages of a long playlist, and Liked Songs, whose pages go through `playlistPage`. A
`GenericError` on a later page used to decode as an empty page and end the walk, cutting the
playlist short without a word; it now fails the load.

The three unions decode `message` and share a `PathfinderEntityUnion` protocol, so the guard
pair written out three times is one generic function.

### 2. One failure value per view

`LoadFailure` holds the message and whether Try again can help, built from the error
(`LoadFailure(error)` asks `isRetryable`) or from an action's message (`LoadFailure(message:)`,
retryable, since Try again reloads the page the message took the place of). The album, artist
and playlist views keep one `@State` of it instead of `errorMessage` and `canRetry`, and so do
the playlist's delete, unfollow, rename and reorder, which used to set the message alone.
`InlineLoadError` takes it and decides about the button itself.

### 3. A miss is remembered for the session

`NotFoundMemory`, one per service, wraps `ensureAlbumLoaded`, `ensureArtistLoaded` and
`ensurePlaylistLoaded`: an id Spotify answered `NotFound` for fails at once on the next visit,
as `TrackService.unavailableTrackIds` does for tracks. Only `NotFound` is remembered.

## Verification

- [x] Unit tests: the measured `GenericError` body throws `entityFailed(.playlist)`,
      which `isRetryable` allows and `notFound` does not; a `PreRelease` album decodes with its
      name; an album answered `NotFound` twice costs one request; a playlist answered
      `GenericError` twice costs two.
- [x] Build, 445 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: `SPOTIFLY_DEBUG_OPEN=spotify:album:2ZWlPOoWh0626oTaHrnl2a` still says the album is not
      found, with no Try again. Choose another album and come back: the message returns at once,
      with no `getAlbum` in the log.
- [ ] Live: albums, artists and playlists load as before, and Liked Songs too.
