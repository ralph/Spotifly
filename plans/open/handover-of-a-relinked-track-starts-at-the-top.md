# A handover of a relinked track starts the queue at the context's first track

Status: **Open**, not planned. Seen once, 2026-09-30, and the cause read from the code and the
log.
Components: `Spotifly/SwiftLibrespot/Proto/TransferState.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (the transfer's take-over),
`Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`start(in:index:uri:)`),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`parseContextReport`)
Found: 2026-09-30, testing #100: Liked Songs started in the web player at #196, "Today Is a
Gift", then taken over from the Mac's Speakers

## Summary

The Mac played the track it was handed, at the right position. But its queue went on from the
first track of Liked Songs, "Welcome to Paradise", and not from #197. The fetch-ahead fetched
"Welcome to Paradise", and the web player, mirroring the Mac, listed it as next.

## Problem

- **The transfer names the track by its relinked id.** It named
  `spotify:track:7dF8hsVoSdDWT6GlJZpBPm`; Liked Songs lists the same song as
  `spotify:track:0sMImBteCIVUKNhcyx3Cyx`. The web player's own row and its track page used the
  listed id, so the relinked one is what its player plays.
- **Only uris are read.** `TransferState` keeps the current track's uri, or one rebuilt from its
  gid, and drops its uid (`ContextTrack` field 2).
- **A uri not in the context goes to the top.** `PlaybackQueue.start(in:index:uri:)` inserts it
  at `index ?? 0`, and a transfer passes no index. So the relinked track became row 0, and the
  context carried on from its first track.
- **The uids exist.** librespot finds the transferred track by uri *or* uid
  (`connect/src/state/transfer.rs`: `c.uri == track.uri || c.uid == track.uid`). A playlist's
  context-resolve answer carries a uid per track: measured 2026-09-30 for Liked Songs
  (`"uid":"95942ae3715ec9d21e76"`) and for a user's playlist. An album's answer carries none, so
  a relinked track in an album would still need another way.

## Solution

Not planned. Two changes:
- Read the current track's uid from the transfer.
- Keep the resolver's uids with the context's uris, which `parseContextReport` drops today. This
  is the same work as part 2 of `plans/open/queue-rows-have-no-identity.md`.

Then `start` matches by uid first, then by uri. For an album without uids, the transfer's own
page of context tracks, where the sender sent one, could give the index.

## Verification

Not defined yet. What it should show: Liked Songs started on another device at a relinked track
and taken over by the Mac, and the Mac's next track is the one after it in Liked Songs.
