# Unknown Now Playing tracks have no shared metadata recovery path

Status: **completed**
Components: `Spotifly/Store/Services/QueueService.swift`,
`Spotifly/Store/Services/TrackService.swift`, `Spotifly/Views/LoggedInView.swift`,
`Spotifly/Views/NowPlayingBarView.swift`, `SpotiflyTests/TrackServiceTests.swift`
Found: 2026-07-31, while reviewing the relinked-track identity fix

## Implemented solution

Completed on 2026-07-31 in three independently verified implementation commits:

- `7b42c78` makes `TrackService` the single metadata-loading owner. Its per-ID registry
  lets overlapping batches join the tasks already carrying some IDs and starts one task
  only for the uncovered remainder. Cache checks happen before token acquisition, failed
  tasks remove their entries for retry, and unstructured tasks survive caller cancellation.
- `1faf499` injects the same persisted `TrackService` instance into `QueueService`. The
  queue keeps its 100 ms ID accumulator but delegates the actual load, removing its former
  parallel metadata task and sharing in-flight work with all other callers.
- `863551c` gives `NowPlayingBarView` an ID-bound recovery task independent of favorite
  loading. Once metadata lands it refreshes macOS Now Playing, which resolves the current
  logical URI and therefore remains safe if the initiating track was skipped meanwhile.

`TrackService.ensureTracksLoaded(trackIds:)` is the one public loading path. Completed
entities are normalized into `AppStore`; rapid changes may therefore cache useful tracks
without ever changing which entity the bar displays.

A later correction completes the one-request-per-ID promise: the store can only cache what
a response contained, so an ID that does not resolve for the user's market stayed absent
and passed the missing-from-store filter on every queue update. IDs that a *successful*
response came back without are now remembered as unavailable and excluded, while a thrown
request still leaves its IDs eligible so a network failure retries.

Automated verification completed:

- five `TrackServiceTests` pass, covering cache hits, overlapping batches, failure/retry,
  caller cancellation, and the pre-existing favorite-status sharing contract;
- `swiftformat --swiftversion 6.3 .` reports no remaining changes;
- `cargo fmt --check`, all 23 Rust tests, and `cargo check` pass;
- repeated full Debug macOS app builds, including the Rust library, succeed.

The Swift test target currently needs `GENERATE_INFOPLIST_FILE=YES` on the command line to
launch. With that override, the loader tests pass. The complete Swift unit suite also runs,
but two existing `NavigationCoordinator` assertions fail (`clearing search prunes search
history entries` and `favorites selection clears drill down state and still records section
history`); neither navigation code nor those tests are part of this change.

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

## Design decision

`TrackService` is the one metadata-loading owner used by both queue hydration and
single-track recovery. Its registry supports overlapping batches, per-ID cache checks,
retry after failure, and caller cancellation without cancelling useful shared work. No
second fetch path was added.

## Acceptance criteria for the follow-up

- [x] An unknown logical current track eventually receives metadata even without another queue
  callback.
- [x] Queue hydration and Now Playing recovery share in-flight work for overlapping IDs.
- [x] A failed metadata request can be retried.
- [x] Rapid track changes may cache every completed entity but never change which entity the bar
  displays.
- [x] Automated tests cover cache hits, overlapping batches, failure/retry, and caller
  cancellation.
