# A track load waits on two metadata requests, one after the other

Status: **Done** 2026-09-29 (#99). Measured from the web player's session, built and unit-tested,
and seen in the running app on 2026-09-30; the time saved not compared with `main`; see
Verification.
Components: `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`prepare`),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`getTrackMetadata` and `getAudioFiles`, now
`getTrack`; `parseAudioFilesResponse` and `parseTrackMetadata`, now `parseTrackResponse`)
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

The plan's second, bigger step, since the measurement allowed it: the load asks only
extended-metadata, and `/metadata/4` is gone from it.

### What was measured

From the web player's own session in Chrome, 2026-09-29, the app's exact extended-metadata
request (`buildTrackRequest`, header `DE`/`premium`, one `TRACK_V4` query), its answer decoded
by field:

| Track | Answer |
|---|---|
| "Not Bad for New Jersey", `2J1gYYXbLb3JJWjbOS6DJO` | 200; `Track` with name (2) "Not Bad for New Jersey", duration (7) sint32 215205, 4 files (12) |
| "The Letter", original `459GknUJgpky3io0y482bi` | 200; name, duration 251293, a restriction (11), no files, 1 alternative (13) |
| "The Letter", DE substitute `7FcObTmCbQYyC8qzlTL2SE` | 200; name, duration 251293, 4 files |
| "Girlfriend", `6PpbRUIbMyUbJkWHS3eQ8j`, withheld in DE | 200; name, duration 201073, a restriction, no files and no alternative |
| `spotify:track:0000000000000000000000` | HTTP 200, the entity's header status 404, no `Track`; `/metadata/4` answered HTTP 404 |

215205 ms is the length the app had logged playing that track the same day. So the wrapped
`Track` carries everything the load read from `/metadata/4`: the name, for the unavailable
message, and the duration. And a withheld track is a `Track` without files, not a missing one:
"Girlfriend", which #57 was about, still reads as withheld and is stepped over. The review of the
change asked for that row, since the track had only been measured through `/metadata/4`.

### What changed

- `SPClient.getTrack(uri:gid:)` is the one request, and `parseTrackResponse` reads the whole
  `Track` from it: name, duration and files, a relinked recording's from its alternative.
- **Which answer decides "not found" stays the same.** A non-200 throws `trackNotFound`, as
  both requests did. A 200 that wraps no `Track`, which is how a track that does not exist
  answers, throws `trackNotFound` too, as `/metadata/4`'s 404 did; the entity's status goes to
  the log. A `Track` with no files is still `trackUnavailable`, which auto-advance steps over.
- The two parsers had treated formats `AudioFormat` does not name differently, and only the
  extended path's rule is left: they are dropped before the alternative is tried, and kept when
  they are all there is.
- `/metadata/4` stays where it is used for something else: `SpclientAPI`'s hydration of the
  store, as JSON.

The first step of the plan, both requests at once, is moot with one request.

## Verification

- [x] Measured, as above.
- [x] Unit tests: the wrapped track's name and its sint32 duration, as measured; an entity with
      no `Track` parses as none; a withheld track, shaped as "Girlfriend" answered, parses with
      its name and no files; the file rules (own files, the alternative, unnamed formats,
      a file without an id), now through the one parser.
- [x] Build, 443 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] Live, 2026-09-30: for a double-click on "Sugar Man", the log shows one `[POST]
      extended-metadata` and no `[GET] …/metadata/4/track/…` before `Decoder open`, 260 ms after
      `Playing <uri>`. Not compared with `main`. Tracks play, the relinked "The Letter" too, and the
      next track is fetched ahead and follows without a gap. The withheld "Girlfriend" is stepped
      over, but the player already knew it and never loaded it, so the load-level case rests on the
      unit test.
