# LoggedInView.init has side effects, so discarded services keep running

Status: **planned**
Components: `Spotifly/Views/LoggedInView.swift`,
`Spotifly/Store/Services/QueueService.swift`,
`Spotifly/Store/Services/ConnectionService.swift`,
`Spotifly/Store/Services/DeviceService.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-08-01, while tracing 18 redundant `/v1/tracks` requests per album start

## Symptom

Starting an album fetches metadata for every queue track that the log has just reported as
already cached. The queue is complete, the UI is correct, and the requests change nothing
a view can see.

That is the visible half. The invisible half is worse: the app runs **two** `AppStore`
instances, and the macOS Now Playing panel resolves its metadata against a different one
than the in-app bar.

## Evidence

`LoggedInView.init` and `QueueService.init` were instrumented with an instance counter and
the identity of the store each one built:

```text
07:36:56.759 LoggedInView] init #1 built store:428
07:36:56.759 QueueService] [svc#1 store:428] init
07:37:09.553 LoggedInView] init #2 built store:180
07:37:09.553 QueueService] [svc#2 store:180] init
07:37:10.196 QueueService] [svc#2 store:180] Set queue: … prev=0, current=1, next=17
07:37:10.196 QueueService] [svc#1 store:428] Set queue: … prev=0, current=1, next=17
07:37:10.196 QueueService] [svc#1 store:428] All 18 unique tracks already cached in store
07:37:10.297 QueueService] [svc#2 store:180] Ensuring metadata for 18 queue tracks
```

Librespot emitted one `EmitSetQueueEvent`, and Swift logged one `handleSetQueueCallback`;
`SpotifyPlayer.setQueue` is a plain `PassthroughSubject` with a single `send`, and
`handleSetQueue` has exactly one caller. Two handler runs therefore mean two live
subscribers, which the tags confirm. No `deinit` ever appears: the second service is not a
brief overlap, it stays.

## Root cause

SwiftUI may run a `View`'s `init` many times and keeps only the **first**
`State(initialValue:)`. `LoggedInView.init` does two things that outlive that discard:

1. **The services subscribe inside their own initialisers.** A service built by a discarded
   init is still wired to the global player subjects, so it keeps handling Spirc
   notifications against the `AppStore` that same init built — a store nothing else reads.
   `QueueService` sees every queue track as missing and re-fetches all of them.

2. **`playbackViewModel.setStore(store)` mutates a singleton** from `init`, so the *last*
   init wins. `PlaybackViewModel.shared` ends up pointing at a store SwiftUI threw away,
   while `.environment(store)` hands the views the one it kept.

Three services subscribe in `init` today:

| Service | Established in `init` |
| --- | --- |
| `QueueService` | queue, setQueue, and the debounced metadata fetch |
| `ConnectionService` | connection-state subscription |
| `DeviceService` | throttled device load, plus `activeDeviceChanged` |

`QueueService` is the one that costs network. The other two write into a discarded store,
which is invisible but equally wrong.

## Why it looks like it works

`PlaybackViewModel.shared` points at the discarded store, and the discarded `QueueService`
is what keeps that store populated. The redundant fetches are currently *load-bearing* for
the system Now Playing panel.

This decides the shape of the fix: the two halves **must land together**.

- Stopping the ghost subscriptions alone starves the store the singleton reads, and the
  system panel loses its metadata.
- Repointing the singleton alone is safe but leaves the waste in place.

It also means the relinked-identity work is quietly violated today: its acceptance
criterion "the system Now Playing panel and in-app bar resolve the same logical track"
cannot hold while the two read different stores.

## Design

### 1. Make construction inert

Give the three services an explicit `activate()` that establishes what their `init`
establishes today. `init` keeps only assignment. A service that is constructed and then
discarded never subscribes and never fetches, whatever SwiftUI does with it.

`activate()` must be idempotent: a `.task` can run again when the view reappears, and the
second call must not double-subscribe. Guard on the stored subscriptions being nil rather
than on a separate flag, so the guard cannot drift from what it protects.

### 2. Activate, and point the singleton, from the surviving view

Move both `activate()` and `playbackViewModel.setStore(store)` into a `.task` on
`LoggedInView`'s content. Everything read there — `store`, `queueService`, and the rest —
comes from `@State`, which is by definition the instance SwiftUI kept. The singleton and
the views then share one store by construction rather than by luck.

### 3. Prefer this over moving construction up a level

Creating the store and services in the parent instead would make the discard rarer, not
impossible: `State(initialValue:)` behaves the same wherever it sits, so a re-created
parent reintroduces the identical bug one level up. The property worth having is that
*construction has no observable effect*, and only moving the effects out of `init` gives
it. This also keeps the diff inside the services and one view.

### 4. Keep a reduced form of the diagnostic

The instance tag on `QueueService`'s log lines is what made this visible at all, and the
same class of bug is invisible without it. Keep the tag; drop the separate
`LoggedInViewInitCounter` and the `deinit` logging once the change is verified.

## Verification

### Automated

```text
xcodebuild -scheme Spotifly -configuration Debug build
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' \
  -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES
```

Two `NavigationCoordinator` assertions fail on this branch and are a known baseline, not a
regression. The Rust side is untouched.

A unit test cannot reach this: the subjects are global statics on `SpotifyPlayer` with no
injection point, and the trigger is SwiftUI's `init` behaviour. Adding an injection seam
purely to test it would be more machinery than the fix. The guard is the runtime check
below, which exercises the real thing.

### Runtime

Capture a log while starting an album from a cold launch.

**Note on capturing:** `debugLog` uses `print`, so Swift lines go to stdout, while
librespot writes to stderr. Piping to `tee` makes stdout block-buffered, so the Swift lines
do not appear until the app exits. Run under a pty to read them live:

```bash
script -q /dev/null env RUST_LOG=librespot=debug,spotifly_rust=debug <app-binary> 2>&1 | tee run.log
```

Then check:

1. Exactly one `svc#` tag appears across all `Set queue` lines, however many times
   `LoggedInView.init` runs.
2. No `Ensuring metadata for N queue tracks` follows a line reporting those same tracks as
   already cached.
3. The store identity in the `QueueService` tag matches the store the Now Playing panel
   resolves against — the panel keeps title, artist, and artwork through a track change.
4. Relinked playback still behaves as `plans/relinked-track-now-playing-identity.md`
   requires; that plan's runtime checklist is the regression suite for this one.

## Acceptance criteria

- One live `QueueService`, `ConnectionService`, and `DeviceService`, regardless of how
  often `LoggedInView.init` runs.
- No metadata request for a track already in the store.
- The in-app bar and the macOS Now Playing panel read the same `AppStore`.
- A constructed-but-never-activated service performs no subscription, request, or store
  write.
- `activate()` called twice does not double-subscribe.
- Build and the Swift test suite pass, baseline failures excepted.
- Add a concise entry under `CHANGELOG.md` → `[Unreleased]` → `Fixed` when implementing.

## Out of scope

The queue-position observation from `plans/relinked-track-now-playing-identity.md`
(`SetQueue` emitted before the requested index is applied) is unrelated and still open.
Nothing here changes which track the queue reports as current.
