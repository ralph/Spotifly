# Tracks the app has not listed are found unplayable only by loading them

Status: **Open**, not planned. Recorded 2026-09-29, left over from
`plans/done/unplayable-tracks-look-playable.md` and #57.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`autoAdvance`, `takeOver`),
`Spotifly/SwiftLibrespot/Public/AutoAdvance.swift`, `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift`,
`Spotifly/PartnerAPI/SpclientEntities.swift`
Found: 2026-09-29, in the reviews of #57 and of its follow-up

## Summary

Playback now steps over a track Spotify withholds without loading it, but only when it knows:
from a list the app has shown, or from an earlier load that failed. The context resolver says
nothing about playability. So a context the app never listed (one started from a phone, a radio
station, a playlist not opened here) is still found out one load at a time, with #57's costs.

## Problem

All read from the code; none has been observed since the follow-up.

- **The skip waits for the end of the track.** The fetch-ahead learns 10 to 30 seconds early
  that the next track is withheld, and nothing acts on it. The change of track then loads the
  one after it cold, where it could have been gapless. The pipeline could report the failed
  fetch-ahead, so the client marks it and names the next one.
- **A run costs a request each, with no cap.** `AutoAdvance.run` tries as many tracks as the
  queue holds, each with an extended-metadata request (one since
  `plans/done/track-load-waits-on-two-metadata-requests.md`; it was `/metadata/4` too).
- **Each attempt shows the track and reports it.** `startTrack` publishes an optimistic
  "playing" state for every track it tries, and the pipeline's `.loading` event reports it to
  the cluster, for as long as its metadata request takes.
- **spclient's metadata is not read for it.** A track hydrated only through spclient, such as
  a queue entry from a context the app never listed, is not greyed. `/metadata/4` has
  `restriction { countries_allowed: "" }` and no `alternative` for a withheld track, but a
  relinked one has the same restriction with an alternative and plays. Reading it needs the
  account's country, which only the accesspoint has.
- **Files the player cannot decode.** A track whose files are all MP3, AAC or FLAC throws
  `trackNotFound("No Ogg Vorbis file available")`, which is not skipped, so auto-advance
  stops there. Spotify has not been seen to serve such a track to a Premium account.
- **A failed transfer reports twice.** `loadAndPlay` gives up playback through
  `playbackFailed`, and `takeOver`'s catch releases again. The cost is one extra PutState.

## Solution

Not planned. The fetch-ahead report is the one that pays most: it would make the first pass
through an unlisted context behave like a listed one.

## Verification

Not planned.
