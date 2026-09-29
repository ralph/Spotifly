# Tracks the app has not listed are found unplayable only by loading them

Status: **Done** 2026-09-29, for its main item, the fetch-ahead report. Built and unit-tested;
not yet seen in the running app; see Verification. The other items moved to
`plans/open/unplayable-track-attempts-cost-and-show.md`. Recorded 2026-09-29, left over from
`plans/done/unplayable-tracks-look-playable.md` and #57.
Components: `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`fetchNextIfDue`, `fetchAhead`,
`Event.withheldAhead`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (the pipeline's
events)
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
The rest of the list, about what each attempt costs, is in
`plans/open/unplayable-track-attempts-cost-and-show.md`.

## Solution

The plan named the fetch-ahead report as the one that pays most, and it is the one done here.

- **The pipeline says so.** The fetch-ahead runs through `AudioPipeline.fetchAhead`, which, when
  the track turns out withheld (`LibrespotError.trackUnavailable`, a `Track` with no files),
  sends a new event, `.withheldAhead(uri)`, and still fails the fetch. Any other failure may not
  recur, so it goes unreported and the change of track fetches again, as before.
- **The client acts on it.** It puts the track in `failedUnplayable`, as a failed load did, and
  announces the next track again. `upcomingPlayable(skipping:)` now steps over the withheld one,
  so the pipeline drops its failed fetch (`setNextTrack` clears an `upcoming` that is no longer
  next) and fetches the track after it, 10 to 30 seconds before the change.
- **So the change of track goes like a listed one.** Auto-advance steps over the withheld track
  without loading it (`AutoAdvance.run` with `knownUnplayable`), and the track after it is the
  one fetched ahead, which the gapless continuation can pick up.

A withheld track still has to be fetched ahead once to be found out; the first pass through an
unlisted context now finds each such track at the fetch-ahead instead of at the change.

## Verification

- [x] Unit tests (`FetchAheadTests`): a withheld track is reported and the fetch still fails;
      another failure is not reported; a track that fetches is not.
- [x] Build, 447 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: play a context the app has not listed, from the phone or a radio, that holds a
      withheld track, such as Liked Songs started on the phone and taken over here, with
      "Girlfriend" coming up. The log shows `… is withheld, found out ahead` during the track
      before it, then `Fetching <the one after> ahead`, and at the change the track after it
      plays from the fetch (`Using … fetched ahead`), with no load of the withheld one.
