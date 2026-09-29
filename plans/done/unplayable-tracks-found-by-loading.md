# Tracks the app has not listed are found unplayable only by loading them

Status: **Done** 2026-09-29, for its main item, the fetch-ahead report. Built and unit-tested;
not yet seen in the running app; see Verification. The other items moved to
`plans/open/unplayable-track-attempts-cost-and-show.md`. Recorded 2026-09-29, left over from
`plans/done/unplayable-tracks-look-playable.md` and #57.
Components: `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`fetchNextIfDue`,
`Event.withheldAhead`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`markUnplayable`),
`Spotifly/SpotifyPlayer.swift` (`PlayerSnapshot.withheld`), `Spotifly/Store/PlayerModel.swift`,
`Spotifly/Store/AppStore.swift` (`setWithheld`), `Spotifly/Views/LoggedInLifecycleModifier.swift`
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

The plan named the fetch-ahead report as the one that pays most, and it is the one done here,
with the greying a review of it found missing.

- **The pipeline says so.** When the fetch-ahead finds the next track withheld
  (`LibrespotError.trackUnavailable`: a `Track` with no files), it sends a new event,
  `.withheldAhead(uri)`, and still fails the fetch. Any other failure may not recur, so it goes
  unreported and the change of track fetches again, as before.
- **The client acts on it.** `markUnplayable`, which a failed load now goes through too, puts the
  track in `failedUnplayable` and publishes it, and the report alone announces the next track
  again. A failed load does not: the code review of the change found that its announcement,
  made mid-way through an auto-advance run, could land after the one the run makes once it has
  moved the queue, and leave the pipeline told the track already playing.
  `upcomingPlayable(skipping:)` steps over the withheld one, so the pipeline drops its failed
  fetch (`setNextTrack` clears an `upcoming` that is no longer next) and fetches the track after
  it on the next tick.
- **So the change of track goes like a listed one.** Auto-advance steps over the withheld track
  without loading it (`AutoAdvance.run` with `knownUnplayable`), and the track after it is the
  one fetched ahead, which the gapless continuation picks up. The fetch-ahead starts ten seconds
  into a track, so this is usually minutes before the change.
- **And the app greys it.** The altitude review of the change found the gap: a listed withheld
  track is stepped over silently because its row is greyed, and one learned this way had a row
  that looked playable, where before its load at the change had at least said "skipped". So the
  client publishes what it has marked, `PlayerSnapshot.withheld`, and the logged-in view hands it
  to `AppStore.setWithheld`, which greys those tracks, now or when the store gets them later,
  as a queue's hydration does. Greyed, they show "Not available on Spotify" like any other.

A withheld track still has to be fetched ahead once to be found out.

## Verification

- [x] Unit tests: a track playback found withheld is greyed and joins `unplayableTrackUris`,
      and one the store only gets afterwards is greyed as it arrives. The pipeline's report is
      a `catch` in the fetch-ahead task, not unit-tested.
- [x] Build, 446 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: play a context the app has not listed that holds a withheld track, such as Liked
      Songs started on the phone and taken over here, with "Girlfriend" coming up. During the
      track before it, the log shows `… is withheld, found out ahead` and then `Fetching <the one
      after> ahead`, and the queue greys "Girlfriend". At the change, the track after it plays
      from the fetch (`Using … fetched ahead`), with no load of the withheld one.
