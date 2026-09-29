# A playlist Spotify cannot find answers HTTP 500

Status: **Done** 2026-09-29. Re-measured, and handled like albums and artists. Built and
unit-tested; not yet seen in the running app; see Verification.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`playlistPage`, `PartnerAPIError`),
`Spotifly/PartnerAPI/PathfinderPlaylist.swift` (`PathfinderPlaylistUnion.typename`),
`Spotifly/Views/PlaylistDetailView.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`
(`SPOTIFLY_DEBUG_OPEN`)
Found: 2026-09-29, while checking the other kinds for `plans/done/album-not-found-reads-as-no-data.md`

## Summary

The plan was recorded from one measurement: a playlist id that does not exist answered HTTP 500
with an empty body. Measured again, it answers HTTP 200 with a `NotFound` union, like albums and
artists. The app read that as "Spotify returned no data", with a Try again that could only get
the same answer. It now says Spotify can't find the playlist, and offers no retry.

## Problem

### The measurement

From a signed-in web player tab, 2026-09-29, with its own request headers and the app's
persisted-query hash, `spotify:playlist:0000000000000000000000`:

| Operation | Variables | Answer |
|---|---|---|
| `fetchPlaylist` | the app's: `offset 0`, `limit 300`, `enableWatchFeedEntrypoint false` | 200 `NotFound` |
| `fetchPlaylist` | the web player's: `limit 25`, `enableWatchFeedEntrypoint true`, `includeEpisodeContentRatingsV2 true` | 200 `NotFound` |
| `fetchPlaylist` | five mixes of the two | 200 `NotFound` |
| `fetchPlaylistContents` | the app's | 200 `NotFound` |
| `fetchPlaylistMetadata` | the app's | 200 `NotFound` |
| `fetchPlaylist`, a real playlist | the app's | 200 `Playlist` |

The body is `{"data":{"playlistV2":{"__typename":"NotFound","message":"Object with uri
'spotify:playlist:0000000000000000000000' not found"}}}`. The web player's own page for that
playlist sent the same query, got the same answer, and showed a spinner that never ended.

The 500 with an empty body was not seen again, in any of these. Nothing recorded which headers
the first replay sent, so it may have been those, or a passing fault.

A malformed id is another answer: `zzzzzzzzzzzzzzzzzzzzzz`, and a 21-character id, answered 200
with `GenericError` and "Failed to fetch playlist for uri …, status code: 400 BAD_REQUEST". The
app only opens ids Spotify gave it, so it does not meet those.

### Not checked

A playlist its owner deleted, and another user's private playlist: neither was at hand, and
making one would mean deleting or hiding a playlist on the account. Either may answer
`NotFound` too, or something else.

### What the app did

`PathfinderPlaylistUnion` did not decode `__typename`. A `NotFound` union has no uri, so
`entities()` returned nil and `PlaylistService` threw `emptyPayload`: "Spotify returned no
data", and a Try again that could only get the same answer.

## Solution

As for albums and artists in #82:

1. `PathfinderPlaylistUnion` decodes `__typename` as `typename`.
2. `playlistPage` throws `PartnerAPIError.notFound(.playlist)` for `NotFound`. It serves
   `fetchPlaylist` and Liked Songs' `fetchPlaylistContents` both.
3. "Spotify can't find this playlist." (de "Playlist wurde nicht gefunden.", fr "Playlist
   introuvable."). It says nothing about why: the unchecked cases above are the likely ways to
   get here, and none was measured.
4. `PlaylistDetailView` keeps a `canRetry`, as the album and artist views do, and shows no Try
   again when `isRetryable` says so, on both of its error lines.
5. `SPOTIFLY_DEBUG_OPEN` opens a `spotify:playlist:` page too, to see it.

Not changed, and recorded in `plans/open/entity-unions-accept-any-typename.md`:

- A `GenericError` union still reads as "Spotify returned no data", with a retry. The three
  guards single out `NotFound` rather than accept only the success name.
- Each of the three views keeps `canRetry` beside its error message by hand.
- A page Spotify cannot find is asked for again on every visit.

## Verification

- [x] Unit test: the measured `NotFound` body makes `playlist(id:)` throw
      `notFound(.playlist)`.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, 2026-09-29.
- [ ] Live: launch with `SPOTIFLY_DEBUG_OPEN=spotify:playlist:0000000000000000000000`. The
      playlist page says "Spotify can't find this playlist." and has no Try again button.
- [ ] Live: open any playlist of the library. It loads as before.
