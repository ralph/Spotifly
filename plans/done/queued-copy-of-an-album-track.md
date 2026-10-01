# A click on an album's copy of a queued track plays the queued one

Status: **Done** 2026-10-01. An album's rows now carry uids. Seen with the web player; see
Verification. What was left of `plans/done/queue-rows-have-no-identity.md`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`play(uriOrUrl:…)`,
`adoptRowUids`), `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`rowUids(_:of:)`,
`adoptRowUids(_:ofContext:)`), `Spotifly/PartnerAPI/PathfinderAlbum.swift` (`rowUids`)
Found: 2026-10-01, measuring the rows' uids

## Summary

The queue's rows carry uids, and a `skip_next` naming one goes to that row. An album's rows had
none, since the context resolver gives an album none, and for such a row the web player sent
none. So when a track was both queued and further on in the album, a click on the album's copy
named only the track, and the queue took its first copy ahead, the queued one. An album's rows
now take the uids pathfinder's `getAlbum` lists for them, so the web player names the row.

## Problem

- Measured 2026-10-01: a double-click on a row of an album in the web player's queue panel sent
  `skip_next` with the track and no uid. For a playlist's row it sent the row's uid, and for a
  queued row `q0`.
- `PlaybackQueue.row(of:uid:nearest:in:)` falls back to the track's first copy ahead when no
  uid is named, as librespot's `handle_next` does.

## Solution

Of the two ways the plan named, the second: **give an album's rows uids.** The first, taking a
`skip_next` without a uid to the first row ahead without one, would have been wrong for a device
that never sends uids, and needed a phone measured first.

- **Asked for beside the resolve.** `play(uriOrUrl:…)` starts the `contextRowUids` request
  (pathfinder `getAlbum`, through `SpotifyPlayer.albumRowUids`) as it starts the context
  resolve. Only an album asks; anything else answers nothing, without a request. A handover
  that needs a row's uid to place its start waits for it, as before, but no longer after the
  resolve, beside it. Anything else does not wait: the audio starts, and the rows take the
  uids when they come (`adoptRowUids`), about 200 ms after the start in the live runs.
- **Only rows without uids, and only the same context.** `PlaybackQueue.adoptRowUids` leaves a
  playlist's own uids alone, and a context that has replaced the album since.
- **Matched by copy.** `PlaybackQueue.rowUids(_:of:)` gives the n-th copy of a track the n-th uid
  pathfinder lists for it. It used to give a track listed twice one uid, on its first row. By
  track rather than by place, since a queued track a handover puts in front of the context, or
  a list of another length, would move every uid after it onto another row.
- **Published without announcing.** The uids go to the app's queue and in the next report to
  other devices, at once if no other load is under way. They do not change the next track, so
  the pipeline is not told it again: during a load, that could cancel a fetched-ahead copy of
  the track being loaded.

The cost the plan named: one `getAlbum` request per album play, in parallel with the resolve.
Not cached: the album page's own `getAlbum` keeps the uids it gets, but not where the player
could read them.

## Verification

- [x] Build, 488 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. New tests: an
      album's rows take the listed uids and a jump naming one goes to the album's copy, not the
      queued one; each copy of a track listed twice gets its own; uids follow tracks, not
      places; none are taken for another context or over a playlist's own.
- [x] Live, 2026-10-01, twice, the second time on the final code: Spotifly played "Not Bad for
      New Jersey" (`SPOTIFLY_DEBUG_AUTOPLAY=1`), `getAlbum` went out with the resolve, and the
      rows had uids 200 ms after the audio started. The web player queued "The Big Sleep"
      (track 4) on Spotifly, and a double-click on the album's copy in its queue panel sent
      `next(trackUri: …7aEd4015g5QiEVNCEgstMS, uid: "f49ba0de22d9241ddf15")`: the album row's
      uid. Spotifly played the album's copy, and the web player still listed the queued copy
      as next in the queue. Before, the same click sent no uid and played the queued copy.
