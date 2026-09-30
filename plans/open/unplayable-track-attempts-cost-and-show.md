# Trying a track Spotify withholds still costs a request, and shows it

Status: **Open**, not planned. What is left of `plans/done/unplayable-tracks-found-by-loading.md`
once the fetch-ahead reported a withheld track. Read from the code; nothing observed.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`startTrack`, `takeOver`),
`Spotifly/SwiftLibrespot/Public/AutoAdvance.swift`, `Spotifly/PartnerAPI/SpclientEntities.swift`
Found: 2026-09-29, in the reviews of #57 and of its follow-up

## Summary

The fetch-ahead now finds a withheld next track before the change of track needs it. A track
nobody fetched ahead, such as the one a double-click or a Next in a track's first ten seconds
lands on, is still found out by loading it, and each such attempt costs a request and shows.

## Problem

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

Not planned. The first two are one change: an attempt could learn the track is withheld from its
metadata before publishing it as playing. The third needs the account's country.

## Verification

Not planned.
