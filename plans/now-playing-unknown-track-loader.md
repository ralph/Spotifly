# Unknown Now Playing tracks have no shared metadata recovery path

Status: **deferred follow-up**
Components: `Spotifly/Store/Services/QueueService.swift`,
`Spotifly/Store/Services/TrackService.swift`, `Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-07-31, while reviewing the relinked-track identity fix

## Gap

The Now Playing bar resolves the logical playback URI strictly through `AppStore.tracks`.
That is the correct identity rule, but an otherwise valid track remains a placeholder when
the store has never seen it — for example playback started externally from a context this
session did not load. The system Now Playing panel can show duration from playback state,
but has no title, artist, or artwork until metadata lands.

`QueueService` covers the common paths by fetching the current track after SetQueue, live
queue updates, and Web API bootstrap. Its metadata request logs and stops on failure; it
does not retry. A playback update without a useful queue callback can also leave no producer
for the entity.

## Why a bar-local loader is not the fix

Adding `TrackService.ensureTrackLoaded(id)` from the bar would create a second request path
that shares no in-flight state with `QueueService.metadataFetchTask`. On an unknown current
track, the bar's immediate task would normally race QueueService's 100 ms debounced fetch.
A per-ID registry inside TrackService could deduplicate TrackService callers, but could not
promise one request overall.

Quickly skipped tracks are not stale-write hazards: normalized entities use different IDs,
all completed fetches may safely land, and the bar continues reading only the current ID.
Cancellation checks or last-writer-wins suppression do not solve the actual duplication.

## Direction for a later design

Create one metadata-loading owner used by both queue hydration and single-track recovery.
The design must support overlapping batches, per-ID cache checks, retry after failure, and
caller cancellation without cancelling useful shared work. Decide whether that belongs in
`TrackService` or a dedicated metadata service before implementation; do not add another
parallel fetch first.

## Acceptance criteria for the follow-up

- An unknown logical current track eventually receives metadata even without another queue
  callback.
- Queue hydration and Now Playing recovery share in-flight work for overlapping IDs.
- A failed metadata request can be retried.
- Rapid track changes may cache every completed entity but never change which entity the bar
  displays.
- Automated tests cover cache hits, overlapping batches, failure/retry, and caller
  cancellation.
