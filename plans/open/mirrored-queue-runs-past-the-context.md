# While another device plays, the queue runs on past the end of its context

Status: **Open**, not planned. Seen once, 2026-09-30; the cause read from librespot, not yet
measured on the wire.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirror`),
`Spotifly/SwiftLibrespot/Proto/Connect.swift` (`ProvidedTrack`),
`Spotifly/Store/Services/QueueService.swift`
Found: 2026-09-30, testing #94 with the web player as the other device

## Summary

The web player played "Not Bad for New Jersey", an album of 11 tracks, with repeat off. Its own
queue ended with track 11, "Wolf by the River". The Mac's Queue section, mirroring it, listed
the album again after track 11, from its first track on. The same happened for "Cold Fact":
12 tracks, and the log said `prev=0, current=1, next=74`.

## Problem

`LibrespotClient.mirror` publishes the cluster's `next_tracks` as they are, and `QueueService`
keeps every row whose uri is a track.

librespot, which builds the same state for its own device, ends a context's rows with a
delimiter (`connect/src/state/tracks.rs`, `new_delimiter`): a row with the uri
`spotify:delimiter`, the uid `delimiter<n>`, provider `context`, and the metadata `hidden` set.
What follows it is the next iteration of the context, there to be played if repeat is on. The
app drops the delimiter row, since it is not a track, and shows the next iteration as if it
came next.

Not measured: what the web player's `next_tracks` hold after the last track, with repeat off
and on. `ProvidedTrack` keeps each row's metadata, so a delimiter or a `hidden` flag would be
readable without a new parser.

## Solution

Not planned. First log the mirrored `next_tracks` (uri, uid, provider, metadata) for an album
played on the web player, with repeat off and with repeat on. If they carry the delimiter:
- `mirror` cuts `nextTracks` at the first delimiter row while repeat-context is off.
- With repeat on, the view shows what the web player's own queue shows.

## Verification

Not defined yet. What it should show: an 11-track album on the web player with repeat off,
and the Mac's queue ends with track 11.
