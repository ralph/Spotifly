# A queued track handed over in an album is placed by its uri

Status: **Done** 2026-10-01, seen in the running app. The bare list the plan also named is
`plans/open/queued-track-handover-in-a-bare-list.md`.
Components: `Spotifly/PartnerAPI/PathfinderAlbum.swift` (`rowUids`), `Spotifly/SpotifyPlayer.swift`
(`albumRowUids`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`contextRowUids`, `play`)
Found: 2026-09-30, measuring the handover of a queued track

## Summary

A handover while a queued track plays names the context row that comes next by its uid, and
Spotifly found that row in a playlist's resolve answer (`plans/done/handover-edge-cases.md`). An
album's answer carries no uids, so there the queued track was still placed by its uri. The uids
are pathfinder's, and Spotifly asks for them when a handover names one the resolver did not list.

## Problem

- **An album.** Measured on "Food In The Belly":
  - The web player played Messages (row 2), then Energy Song, queued from row 5.
  - The transfer's `current_uid` was `641b0e01bced253ac901`. Our resolve answer for the album
    has no uids to match it against.
  - Spotifly found Energy Song by its uri at row 5, and the context went on with row 6,
    passing over rows 3 and 4.
- **Where the uids come from.** Measured on 2026-10-01 by watching the web player's own requests
  while it opened the album: pathfinder's `getAlbum` lists each `albumUnion.tracksV2.items[]` as
  `{track, uid}`. The third row, Pockets Of Peace, carries `641b0e01bced253ac901`. The first two
  carry `5222ba0634a72c2f7ce3` and `234c241ed2b13766c70e`, the uids the transfers named for The
  Letter and Messages.
- **An undocumented alternative**, not taken: every transfer measured carried a field 6, not in
  librespot's `transfer_state.proto`, that looks like a play history of `{uid, uri, timestamp}`
  entries.

## Solution

- **`PathfinderAlbumUnion.rowUids`**: each row's uid by its track's uri, from `tracksV2.items`,
  which now decodes `uid` beside `track`.
- **`LibrespotClient.initialize(…contextRowUids:)`**: a provider for a context's row uids by track
  uri, which the app sets to `SpotifyPlayer.albumRowUids`, a `getAlbum` for an album uri and
  nothing for anything else. The client knows no pathfinder, as it knows no keymaster grant but
  through its token provider.
- **`play()` asks it only when a handover names a uid the resolver's answer does not list**, and
  places the start with those uids instead. A playlist, whose answer lists them, and every play
  that names no uid cost no second request.

## Verification

- [x] Unit test: `rowUids` from the recorded `getAlbum` fixture.
- [x] Build, 469 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] In the running app, 2026-10-01, with the web player as the other device and the Connect
      device chosen by its name. The measured case again: the web player played Messages, then
      the queued Energy Song, and handed over. Spotifly asked `getAlbum` once and showed
      Messages in the history, Energy Song playing, marked Q, then Pockets Of Peace, Fortune
      Teller, Energy Song and The Mother: the web player's own queue, row for row.
