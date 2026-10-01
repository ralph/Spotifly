# Trying a track Spotify withholds still costs a request, and shows it

Status: **Done** 2026-10-01, for the item that shows: a withheld track is found out before
anything says it plays. Seen in the running app; see Verification. The other items
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

- **`AudioPipeline.playTrack` asks for the metadata first**, through `resolveFile(for:)`, the
  first half of what `prepare` did, while what plays goes on playing. A track with no files
  throws `trackUnavailable` there, before anything is published. What played before is then
  torn down, as it was when a load failed after its announcement, so a failed start leaves
  nothing playing, as before. That happens in the pipeline, under the load's generation,
  rather than as a stop in the client's failure path, which could land on a newer load. The
  file found is handed to `download(_:of:)`, the second half, so the load still makes one
  metadata request.
- **A track with a copy in memory is not asked about** (`hasCopy(of:)`): the loaded track, the
  one decoding behind it for a gapless change, and the one fetched ahead, which asked already,
  or is asking, and reports a withheld one itself (`.withheldAhead`). So a Next onto the
  fetched-ahead track, the usual case, waits for nothing. A Next that lands in the moment
  while the fetch ahead's own metadata request is out still announces the track first.
- **The load generation is taken when the load starts**, not after the teardown: a stop or a
  newer load that comes during the metadata request supersedes it, and it throws
  `CancellationError` without announcing anything.
- **`.loading` now carries the position and whether the track is held paused**, and
  `LibrespotClient.handlePipelineState` publishes the track from it, with its queue in one
  snapshot, where `startTrack` used to publish it optimistically before the load. The events
  are handled in order, so a stop that comes later cannot be overtaken by a late publish.
- **A track that followed on without a gap is never `.loading`**, so its `.playing` now
  publishes with the queue too, which `startTrack`'s optimistic state used to carry.
- **A new context's queue is published after its load**, as the skips' already was
  (`play(contextUri:…)`, which replaces `setQueue`). Published before, it showed the new track as
  the current row while the bar still showed the old one, for the length of the metadata
  request, and its announcement of the next track could cancel a fetched-ahead copy of the
  track being loaded.
- **Recovery's reload** calls `playTrack` directly, and now publishes its track and position from
  the same event.
- **The announcement carries the track's length** where the load knows it, from the metadata or
  the copy it plays from, and the cluster report takes the length from the local state. Found
  in the live check: the report read the pipeline's `durationMs`, which is the previous track's
  until the new one has loaded, so the first report of every new track carried the old length,
  and the web player showed "Twist in My Sobriety" as 3:53, Tilted's, where it is 4:52, until
  the next heartbeat. That was so before this change too.
- **What still sees the moved queue early:** a cluster report sent during the metadata request,
  such as a remote command's acknowledgement, pairs the old track with the new queue around
  it, until the announcement reports again 16 to 44 ms later.

**The bar waits for one metadata request** on a start nobody fetched ahead. Measured in this
session's logs: 16 to 44 ms from the request to its answer (`I Took A Pill In Ibiza` 20 ms,
`Pockets Of Peace` 19 ms, `Crucify Your Mind` 44 ms). Audio starts no later than before, since
the load needed the metadata first anyway, and the old track plays on through it instead of
falling silent.

## Verification

- [x] Build, 473 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. The pipeline
      needs a network for a load, so the new order is not unit-tested.
- [x] Live, 2026-10-01, with the web player as the other device:
  - **Withheld:** Liked Songs started from the web player on the Mac at "Today Is a Gift", the
    track before "Girlfriend", and Next pressed four seconds in. The log showed
    `Track 'Girlfriend (feat. Dâm-Funk)': 0 file(s)` 19 ms after its metadata request, no
    `Playing` line and no state update naming it, and no PutState but the release ("no player
    state"). Next then reported it not available, which
    `plans/open/skip-onto-a-withheld-track-stops-playback.md` is about.
  - **Next onto the fetched-ahead track:** `Playing` straight after the press, no metadata
    request; the bar's track and the queue in the same millisecond.
  - **A remote play of an uncached track:** metadata 18 ms, then the announcement with the
    track's length; bar and queue in the same millisecond; audio 230 ms later.
  - **Gapless:** the next track's first state update carried its own length (194186 ms) and the
    queue moved with it; the web player showed 3:14 at once.
  - **Paused handover** from the web player: arrived paused at 96220 ms, announced with its
    length.
  - **The length in the report:** after the fix, a Next showed the new track's 2:53 in the web
    player at once.
