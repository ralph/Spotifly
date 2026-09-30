# The queue's header names no context for Liked Songs, or a list the store has not loaded

Status: **Open**, not planned. Seen 2026-09-30, and the cause read from the code.
Components: `Spotifly/Views/QueueListView.swift` (`contextInfo`), `Spotifly/SpotifyPlayer.swift`
(`QueueState`), `Spotifly/SwiftLibrespot/Network/SPClient.swift` (the context-resolve answer),
`Spotifly/PartnerAPI/PathfinderLibrary.swift` (`LikedSongs`)
Found: 2026-09-30, testing #100: Liked Songs playing on the Mac

## Summary

While Liked Songs plays, the Queue section's header says "Wiedergabe auf Spotifly" and names no
context, where an album says "Wiedergabe von „Alive“ auf …". The same holds for any playlist,
album or artist the store has not loaded, such as one started on another device.

## Problem

`QueueListView.contextInfo` names the context only from the store: `store.albums`,
`store.playlists` or `store.artists`, by the uri's kind. Liked Songs plays as
`LikedSongs.uri`, `spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ`, a constant the web player uses for
every account. It is not in `store.playlists`, so there is no name. Before #91 the header read
"Playing from "Queue"" in this case, which was no better.

The name is at hand elsewhere. The context-resolve answer names the context in its metadata,
`context_description`: measured 2026-09-30, "Lieblingssongs" for Liked Songs and
"Spotifly test: Girlfriend" for a playlist. The cluster probably has the same in its context
metadata while another device plays; not measured.

## Solution

Not planned. Two depths:
- **Liked Songs alone:** `contextInfo` knows `LikedSongs.uri`, names it as the Favorites section
  does, and links to Favorites.
- **Any context:** the queue is published with the context's name from the resolve answer, or
  from the cluster when mirroring, and the store's name only overrides it. This also names a
  context the store has not loaded. The link still needs the store, or a kind and id to open
  the page by.

## Verification

Not defined yet. What it should show: play Liked Songs, and the header says "Wiedergabe von
„Lieblingssongs“ auf …", with the name linking to Favorites.
