# A track load waits on two metadata requests, one after the other

Status: **Open**, not planned. Recorded 2026-09-29 in the review of #57.
Components: `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`prepare`),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`getTrackMetadata`, `getAudioFiles`,
`parseAudioFilesResponse`)
Found: 2026-09-29, an efficiency review of #57

## Summary

Every track load asks spclient for the track twice, and waits for the first answer before
sending the second request. The first answer has never carried what the load needs. A load
not fetched ahead pays two round trips before the audio key and the CDN url are even asked
for. That includes Next through the first ten seconds of a track, a double-click, a
handover, and a skip past an unavailable track.

## Problem

`AudioPipeline.prepare` calls `SPClient.getTrackMetadata` (`/metadata/4/track/<gid>`) first.
Only if that lists no files, which is what it answers these days, does it call
`SPClient.getAudioFiles` (the extended-metadata `TRACK_V4` request).

- **The first request is almost always wasted.** `SPClient` says `/metadata/4` "answers with
  a stub (title, duration, no files) these days", and every live log on 2026-09-29 showed
  `files=0` from it. The files come from extended-metadata.
- **The second answer may carry everything.** `parseAudioFilesResponse` notes that its leaf is
  a `google.protobuf.Any` wrapping "the full `Track`", from which only the files are read. If
  that `Track` carries the name (field 2) and the duration (7), `/metadata/4` is not needed
  at all. Not checked.
- **The two failures differ.** A non-200 from either throws `trackNotFound`. Dropping one
  request changes which answer decides that.

The fetch-ahead hides this for auto-advance and a late Next. #57 made a skip past an
unavailable track pay it in full, once per skipped track.

## Solution

Not planned yet. In order of effort:

1. Send both requests at once with `async let`: the same two requests, one round trip less.
2. Check whether the extended-metadata `Track` carries the name and the duration. If it does,
   read them from there and drop `/metadata/4` from the load path.

## Verification

None yet. A plan would measure the time from `Playing <uri>` to `Decoder open` in the
`AudioPipeline` log for a load that was not fetched ahead, before and after.
