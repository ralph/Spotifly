# A playlist Spotify cannot find answers HTTP 500

Status: **Open.** Recorded, not planned. No path in the app is known to reach it.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`playlist(id:)`, `playlistPage`),
`Spotifly/Views/PlaylistDetailView.swift`
Found: 2026-09-29, while checking the other kinds for `plans/done/album-not-found-reads-as-no-data.md`

## Summary

Albums and artists that Spotify has none of answer HTTP 200 with a `NotFound` union, and the
app now says so. A playlist does not: `fetchPlaylist` for a playlist id that does not exist
answers HTTP 500 with an empty body. The playlist page would show "Spotify rejected the request
(HTTP 500)" and a Try again that can only fail.

## Problem

Measured from the web player on 2026-09-29, with the app's variables (`offset: 0`,
`limit: 300`, `enableWatchFeedEntrypoint: false`): `spotify:playlist:0000000000000000000000`
answered HTTP 500, empty body. Not checked:

- a playlist that existed and was deleted by its owner;
- a private playlist of another user;
- `fetchPlaylistContents` and `fetchPlaylistMetadata`, which share the hash.

A 500 is also what a real server failure looks like, so the status alone cannot tell "no such
playlist" from "try again later".

## Solution

Not planned yet. First measure the unchecked cases above. If a deleted or private playlist
answers something recognisable, `playlist(id:)` can throw `PartnerAPIError.notFound` the way
`album(id:)` does. If every case is a bare 500, the app cannot tell, and the retry should stay.

## Verification

Not defined yet.
