# QueueItem carries seven fields nothing sets

Status: **Open.** Recorded, not planned. Not urgent.
Components: `Spotifly/SpotifyPlayer.swift` (`QueueItem`), `Spotifly/Views/TrackRow.swift`
(`QueueItem.toTrack`), `Spotifly/Store/Services/QueueService.swift`,
`SpotiflyTests/QueueBootstrapTests.swift`
Found: 2026-08-15, as the last question left from the old `plans.txt`. Re-checked 2026-09-29,
which made it concrete.

## Summary

`QueueItem` has a name, artist, image, duration and three ids, shaped for the FFI. Since #65
the player fills only its uri and provider, and the store keeps queue entries as a track id and
a provider. The other seven fields are always empty, and the conversion that read them has no
callers.

## Problem

- The player builds every `QueueItem` through `init(uri:provider:)` in `LibrespotClient.swift`,
  "a metadata-less placeholder; names hydrate through the store". Name, artist name, image
  url, duration, album id, artist id and external url stay empty.
- `QueueService.queueEntry(from:)` reads only `uri` and `provider`, into `QueueEntry`.
- `QueueItem.toTrack()` in `TrackRow.swift` converts the empty fields into a `Track`. Nothing
  calls it.
- `QueueBootstrapTests` still build `QueueItem` with every field, which the app never does.

`plans.txt` asked the same question of four more types. `TrackRowData`, `TrackMetadata`,
`APIPlaylist` and `SpotifyDevice` are deleted, and `APITrack` went with the Web API, so this is
the last one.

## Solution

Not planned. Reduce `QueueItem` to `uri` and `provider`, or replace it with `QueueEntry`
across the snapshot, and delete `toTrack()`.

## Verification

Build and unit tests pass, and the Queue section and now-playing bar still show names and
artwork, which come from the store.
