# A handover of a relinked track starts the queue at the context's first track

Status: **Done** 2026-09-30. Measured from the transfers of the web player and a speaker,
unit-tested, and seen in the running app; see Verification.
Components: `Spotifly/SwiftLibrespot/Proto/TransferState.swift` (`currentTrackUid`),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`ResolvedContext.uids`, `parseContextReport`),
`Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`start(in:index:uri:uid:uids:)`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`play`, the transfer's take-over, the
take-over of a mirrored queue, `mirroredQueue`)
Found: 2026-09-30, testing #100: Liked Songs started in the web player at #196, "Today Is a
Gift", then taken over from the Mac's Speakers

## Summary

The Mac played the track it was handed, at the right position, but its queue went on from the
first track of Liked Songs, "Welcome to Paradise", not from #197. Now a handover finds the row
by its uid, and the queue goes on from there.

## Problem

- **The transfer names the track by its relinked id.** The web player named
  `spotify:track:7dF8hsVoSdDWT6GlJZpBPm`; Liked Songs lists the same song as
  `spotify:track:0sMImBteCIVUKNhcyx3Cyx`.
- **Only uris were read.** `TransferState` kept the current track's uri, and dropped its uid
  (`ContextTrack` field 2).
- **A uri not in the context went to the top.** `PlaybackQueue.start(in:index:uri:)` put it in
  at `index ?? 0`, and a transfer passes no index. So the relinked track became row 0, and the
  context carried on from its first track.

### Measured

- **The transfer carries the row's uid.** The web player's transfer of "today is a gift" named
  `7dF8…` with uid `6725e43cd5e60a1a9c99`, the same as the session's `current_uid`. A speaker's
  transfer of the same row named the listed `0sMI…` with the same uid.
- **A playlist's resolve answer has a uid per track**, Liked Songs included; an album's has none
  (from the app's own log of resolve answers).
- librespot finds the transferred track by uri *or* uid (`connect/src/state/transfer.rs`).

A remote play command was not affected: the web player names the id the context lists, as
measured for `plans/done/clicked-row-plays-another-track.md`. Its `skip_to` also carries the
row's uid, which is now passed on too.

## Solution

- `SPClient.parseContextReport` keeps each track's `uid` beside its uri, nil where the answer has
  none, and `ResolvedContext.uids` carries them.
- `TransferState.currentTrackUid` reads the current track's uid; nil when it plays from the
  queue, where the uid names a queue row.
- `PlaybackQueue.start` takes a uid and the context's uids. A uid the context lists names the
  row and comes first; otherwise the uri decides as before. The row keeps the context's own uri:
  a relinked track plays through its alternatives either way.
- `play(uriOrUrl:…startingAtUid:)` passes it through: from the transfer's take-over, from the
  take-over of a mirrored queue, whose current track now keeps its uid, and from a remote play
  command's `skip_to.track_uid`.
- The same uid also picks the right copy of a track a playlist holds twice, which the uri alone,
  without an index, took as the first.

An album's relinked track is still placed by uri alone, since its resolve answer has no uids.
That, a handover while a queued track plays, and a handed-over bare list are in
`plans/open/handover-edge-cases.md`.

## Verification

- [x] Measured, as above.
- [x] Unit tests: a uid names the row a relinked track plays from, and which copy of a repeated
      track; a uid the context does not list leaves the uri to decide; the transfer's current
      uid comes through, and not a queued track's; a remote play's `skip_to` uid is read; a
      resolve answer's uids are kept, and an album's are nil; the mirrored current track keeps
      its uid.
- [x] Build, 461 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] Live, 2026-09-30: Liked Songs played in the web player at #196, "today is a gift", and
      handed to the Mac from the web player's Connect menu. The transfer named `7dF8…` with its
      uid; the Mac played the listed `0sMI…` from 18.8 s, and fetched ahead "Girlfriend"
      (withheld, found out ahead) and then "Tilted", #197 and #198. Before, the next track was
      "Welcome to Paradise", #1.
