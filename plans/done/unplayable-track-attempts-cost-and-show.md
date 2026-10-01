# Trying a track Spotify withholds still costs a request, and shows it

Status: **Done** 2026-10-01, for the item that shows: a withheld track is found out before
anything says it plays. Unit tests pass; live check pending, see Verification. The other items
moved to `plans/open/withheld-tracks-left-to-find-out.md`, and a problem found on the way to
`plans/open/skip-onto-a-withheld-track-stops-playback.md`. What was left of
`plans/done/unplayable-tracks-found-by-loading.md` once the fetch-ahead reported a withheld track.
Components: `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`playTrack`, `playableMetadata`,
`AudioPlaybackState.loading`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`
(`startTrack`, `handlePipelineState`)
Found: 2026-09-29, in the reviews of #57 and of its follow-up

## Summary

The fetch-ahead finds a withheld next track before the change of track needs it. A track nobody
fetched ahead, such as one a double-click, a remote play, or a Next in a track's first ten
seconds lands on, was found out by loading it. Each attempt was shown in the bar and reported to
other devices as playing, for as long as its metadata request took. It now is not: the load asks
for the metadata first and announces the track only once it has a file to play.

## Problem

As recorded, read from the code:

- **A run costs a request each, with no cap.** `AutoAdvance.run` tries as many tracks as the
  queue holds, each with an extended-metadata request. *Still so; moved.*
- **Each attempt shows the track and reports it.** `startTrack` published an optimistic
  "playing" state for every track it tried, and the pipeline's `.loading` event reported it to
  the cluster, for as long as its metadata request took. *Done here.*
- **spclient's metadata is not read for it**, which needs the account's country. *Moved.*
- **Files the player cannot decode**, never seen from Spotify. *Moved.*
- **A failed transfer reports twice.** *Moved.*

## Solution

**The pipeline decides when a load is announced, and the client shows what it announces.**

- **`AudioPipeline.playTrack` asks for the metadata first**, through `playableMetadata(for:)`,
  while what plays goes on playing. A track with no files throws `trackUnavailable` there,
  before anything is published. What played before is then torn down, as it was when a load
  failed after its announcement, so a failed start leaves nothing playing, as before. The
  metadata is handed on to `prepare`, so the load still makes one metadata request.
- **The loaded track and the one fetched ahead are not asked about again**: the first played,
  and the fetch-ahead asked already, or is asking, and reports a withheld one itself
  (`.withheldAhead`). So a Next onto the fetched-ahead track, the usual case, waits for nothing.
- **The load generation is taken when the load starts**, not after the teardown: a stop or a
  newer load that comes during the metadata request supersedes it, and it throws
  `CancellationError` without announcing anything.
- **`.loading` now carries the position and whether the track is held paused**, and
  `LibrespotClient.handlePipelineState` publishes the track from it, with its queue in one
  snapshot, where `startTrack` used to publish it optimistically before the load. The events
  are handled in order, so a stop that comes later cannot be overtaken by a late publish.
- **A track that followed on without a gap is never `.loading`**, so its `.playing` now
  publishes with the queue too, which `startTrack`'s optimistic state used to carry.
- **Recovery's reload** calls `playTrack` directly, and now publishes its track and position from
  the same event.

**The bar waits for one metadata request** on a start nobody fetched ahead. Measured in this
session's logs: 16 to 44 ms from the request to its answer (`I Took A Pill In Ibiza` 20 ms,
`Pockets Of Peace` 19 ms, `Crucify Your Mind` 44 ms). Audio starts no later than before, since
the load needed the metadata first anyway, and the old track plays on through it instead of
falling silent.

## Verification

- [x] Build, 473 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. The pipeline
      needs a network for a load, so the new order is not unit-tested.
- [ ] Live: a withheld track nobody fetched ahead, started remotely or by Next in a track's first
      ten seconds, never appears in the bar or in a PutState, and the log shows its metadata and
      no `Playing <it>` line. A normal Next and a double-click change the bar and the queue
      together, and a gapless change of track shows the new track with its queue.
