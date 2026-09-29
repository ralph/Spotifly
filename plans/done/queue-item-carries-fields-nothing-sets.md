# QueueItem carries seven fields nothing sets

Status: **Done** 2026-09-29. Built and unit-tested; see Verification.
Components: `Spotifly/SpotifyPlayer.swift` (`QueueItem`), `Spotifly/Views/TrackRow.swift`
(`QueueItem.toTrack`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (the
placeholder initializer, the mirrored queue), `SpotiflyTests/QueueBootstrapTests.swift`
Found: 2026-08-15, as the last question left from the old `plans.txt`. Re-checked 2026-09-29,
which made it concrete.

## Summary

`QueueItem` had a name, artist, image, duration and three ids, shaped for the FFI. Since #65
the player filled only its uri and provider, and the store keeps queue entries as a track id and
a provider. The other seven fields were always empty, and the conversion that read them had no
callers. `QueueItem` is now its uri, its provider and the cluster's uid.

## Problem

- The player built every `QueueItem` through `init(uri:provider:uid:)` in `LibrespotClient.swift`,
  "a metadata-less placeholder; names hydrate through the store". Name, artist name, image
  url, duration, album id, artist id and external url stayed empty, and `id` repeated the uri.
- `QueueService.queueEntry(from:)` reads only `uri`, `provider` and `uid`, into `QueueEntry`.
- `QueueItem.toTrack()` in `TrackRow.swift` converted the empty fields into a `Track`. Nothing
  called it. Nor did anything read `durationFormatted` or `imageURL`, or use the type as
  `Identifiable` or `Encodable`.
- `QueueBootstrapTests` still built `QueueItem` with every field, which the app never did.

`plans.txt` asked the same question of four more types. `TrackRowData`, `TrackMetadata`,
`APIPlaylist` and `SpotifyDevice` are deleted, and `APITrack` went with the Web API, so this was
the last one.

## Solution

The plan offered two shapes: reduce `QueueItem` to `uri` and `provider`, or replace it with
`QueueEntry` across the snapshot. Reduced, because the two stand on either side of a real
boundary. `QueueItem` is what the player publishes: a uri of any kind, since the cluster can
carry episodes and ads, and the provider as the wire's string. `QueueEntry` is what the store
keeps: only tracks, keyed by track id, with the provider parsed. `QueueService` is where one
becomes the other and drops what the app has no row for.

- `QueueItem` is `uri`, `provider` and `uid`, with the memberwise initializer. The placeholder
  initializer is gone; it existed to fill the empty fields, and to turn a proto3 empty uid into
  nil, which the one caller with uids, the mirrored queue, now does itself.
- `toTrack()` is deleted.
- `QueueBootstrapTests` build items the way the app does.

## Verification

- [x] Build, 441 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. The
      compiler found no reader of the removed fields.
- [ ] Live: the Queue section and the now-playing bar still show names and artwork, which come
      from the store, for local playback and while another device plays.
