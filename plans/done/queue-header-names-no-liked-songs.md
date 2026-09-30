# The queue's header names no context for Liked Songs, or a list the store has not loaded

Status: **Done** 2026-09-30. Measured from the resolver's and the cluster's answers,
unit-tested, and seen in the running app for Liked Songs and an album; see Verification.
Components: `Spotifly/Views/QueueListView.swift` (`contextInfo`), `Spotifly/SpotifyPlayer.swift`
(`QueueState.contextName`), `Spotifly/SwiftLibrespot/Network/SPClient.swift` (`resolveContext`,
`parseContextReport`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`setQueue`,
`mirroredQueue`, `queueState`)
Found: 2026-09-30, testing #100: Liked Songs playing on the Mac

## Summary

While Liked Songs played, the Queue section's header said "Wiedergabe auf Spotifly" and named no
context, where an album says "Wiedergabe von „Alive“ auf …". The same held for any playlist,
album or artist the store had not loaded, such as one started on another device. Now the header
names them, Liked Songs as "Favoriten" with a link to that section.

## Problem

`QueueListView.contextInfo` named the context only from the store: `store.albums`,
`store.playlists` or `store.artists`, by the uri's kind. Liked Songs plays as
`LikedSongs.uri`, `spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ`, a constant the web player uses for
every account. It is not in `store.playlists`, so there was no name. Before #91 the header read
"Playing from "Queue"" in this case, which was no better.

The name was at hand elsewhere, measured 2026-09-30:
- **The resolver's answer** has `metadata.context_description`: "Lieblingssongs" for Liked Songs,
  "Spotifly test: Girlfriend" for a playlist, "Cold Fact" for an album.
- **The cluster's context metadata** has the same key while another device plays: "Not Bad for
  New Jersey" for an album the web player played.

## Solution

The name travels with the queue, from where the player learns what it plays:
- `SPClient.resolveContext` returns the answer's `context_description` as the context's `name`.
- `LibrespotClient` keeps it beside the queue, set with the context in `setQueue`, the one path
  that replaces the context. `PlaybackQueue` stays uri-level, and the rewind to the context's
  start at its end, which keeps the context, keeps the name.
- `QueueState.contextName` carries it. Locally it comes from the resolver; while another device
  plays, from the cluster's context metadata, in `mirroredQueue`.
- `QueueListView.contextInfo` takes the app's own name first, as the one it shows everywhere
  else: the store's, and for Liked Songs, recognised by `LikedSongs.uri`, the Favorites
  section's title, since its link opens that section. The player's name covers the rest.
- The name no longer depends on a page to link to. An album, playlist or artist links to its
  page as before, and Liked Songs to Favorites. A context with no page, such as a radio station,
  shows its name as plain text.

### Left for later

From the altitude review; see `plans/open/context-uris-open-one-way.md`:
- The header's uri-to-page mapping is the second one in the app, beside `SPOTIFLY_DEBUG_OPEN`'s,
  and only this one knows Liked Songs.
- This Mac does not report `context_description` in its own cluster state, as librespot does.
  Whether other devices name its context without it is not measured.

A bare list of tracks still names nothing: it has no context.

## Verification

- [x] Measured, as above.
- [x] Unit tests: the resolver's answer names its context, and an empty description names
      nothing; the mirrored queue carries the cluster's name, and an empty one names nothing.
- [x] Build, 456 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] Live, 2026-09-30: playing Liked Songs, the header says "Wiedergabe von „Favoriten“ auf
      Spotifly", and the name opens Favorites. An album still reads "Wiedergabe von „Not Bad for
      New Jersey“ auf Spotifly".
- [ ] Live: another device plays a playlist the Mac has not loaded, and the header names it. Not
      run; the mirrored name is unit-tested from the measured metadata.
