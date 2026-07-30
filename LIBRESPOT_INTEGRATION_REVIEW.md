# Librespot Integration Review

Review date: 2026-07-30

Scope: static review of the current Swift app, C FFI, Rust wrapper, and the
`spotifly-dev` librespot sources. No live Spotify session or forced-outage test was
run as part of this review.

## Executive summary

The integration has the right building blocks: Rust pushes playback and connection
updates, Swift can pull an initial snapshot, Rust retries short network failures with
backoff and fresh tokens, and a generation protects against stale cluster listeners.

The brittleness comes mainly from overlapping meanings and recovery owners:

- librespot's patched `SessionConnected` and `SessionDisconnected` player events
  describe Spotify Connect device activation, but Spotifly treats them as network
  session health.
- Rust owns automatic reconnect, while Swift can concurrently tear everything down
  and initialize it again.
- Swift combines Rust callbacks, synchronous Rust polling, optimistic UI changes,
  and Web API snapshots without a freshness rule.

The smallest robust direction is:

1. Let Rust be the sole owner of the librespot lifecycle and reconnect loop.
2. Publish one authoritative, versioned Rust snapshot to Swift.
3. Treat Web API state as bootstrap/fallback data only.
4. Make command acceptance visible instead of discarding every FFI result.

This does not require a large state machine, a general retry framework, or handling
every theoretical edge case.

## Official librespot versus `spotifly-dev`

### Current branch delta

The history makes the fork look larger than it is. `spotifly-dev` is 38 commits ahead
of `dev`, but `dev` is its merge base and the final trees differ in only four files:

```text
CHANGELOG.md          +2
connect/src/model.rs +11
connect/src/spirc.rs +15/-11
src/main.rs           +1/-1
```

The original Spotifly requirements have already been upstreamed:

- `Spirc::add_to_queue` is present in official `dev` (upstream #1676).
- opt-in `PlayerEvent::SetQueue` support is present in official `dev`
  (upstream #1677).
- `ConnectConfig.emit_set_queue_events`, `QueueTrack`, and `Player::set_session`
  are available in official `dev`.

The remaining differences are:

| Difference | Behavioral requirement for Spotifly |
| --- | --- |
| `SpircPlayStatus::is_playing()` and using local play intent for next/previous transitions | Fixes a real timing problem where remote-facing `ConnectState` can lag during loading/reconnect transitions |
| Adopt the first Player `play_request_id` when a new Spirc has none | Required by Spotifly's current soft reconnect, which keeps the Player alive and attaches a new Spirc to it |
| Move a `context_uri` read before borrowing player state | No intended behavior change |
| Use `ConnectConfig::default()` for the CLI's remaining field | No effect on the Spotifly library integration |
| Changelog entries | Documentation only |

The two behavioral changes come from one focused commit. A local upstream-PR draft
describes them as a general, backwards-compatible fix, but they are not in the
current official `dev` tree.

### Compatibility check

The current, unmodified Spotifly Rust wrapper passes `cargo check` against an exported
copy of official `dev` at commit `9c7d75615fc093bdcbdb29adbce3fed38c531852`.
This proves source/API compatibility, including queue APIs. It does not prove runtime
reconnect behavior.

The latest local release tag is `v0.8.0`; official `dev` is 16 commits newer and
contains the queue APIs Spotifly uses. Therefore a migration today should pin the
tested official commit (or a later official release containing those commits), not
silently use the older `v0.8.0` sources and not track a moving branch.

### What would regress with an immediate branch switch

The current soft reconnect deliberately retains the Player and swaps in a new
Session/Spirc ([`rust/src/lib.rs`](rust/src/lib.rs), around lines 1053-1139). A new
official Spirc starts with no `play_request_id` and rejects Player events whose ID it
cannot match. Without the fork patch, it can ignore events from the retained Player,
including events needed for end-of-track and queue transitions.

The second patch also avoids loading the next/previous track paused when local play
intent and the deferred remote-facing Connect state temporarily disagree.

Consequently, changing only the dependency branch is compile-safe but not
behavior-safe.

### Options

#### Keep the minimal fork

Advantages:

- Preserves uninterrupted soft reconnect and the current transition fix.
- The actual delta is small and easy to review.
- Both changes are reasonable upstream candidates.

Costs:

- Spotifly remains coupled to a non-standard Player/Spirc lifetime.
- Every official update still requires rebasing and retesting the patch.
- The soft reconnect is a major source of the lifecycle races described in P0.2.
- The branch history obscures that only one meaningful patch remains.

If this option is kept temporarily, rebuild `spotifly-dev` as one clean commit on top
of official `dev` rather than carrying the historical 38-commit chain, and submit the
behavioral fix upstream.

#### Return to unmodified official librespot

To do this safely, remove the integration behavior that requires the patch:

1. On a real transport failure, capture only the latest playback intent:
   context/track, position, playing/paused, and any explicit play request still
   pending.
2. Rebuild Session, Player, Mixer, and Spirc together as one generation.
3. If Spotifly was the active device, issue one deterministic `LoadRequest` against
   the new Spirc to restore that intent.
4. If Spotifly was inactive, remain passive and accept the cluster/Web bootstrap
   state.
5. Remove `soft_reconnect_async`, `do_soft_reconnect_cleanup`, the
   `Player::set_session` path, and the soft-reconnect pending-play watchdog.

This may cause a short audible interruption during a network outage. In return,
Player and Spirc lifetimes match official librespot's normal model, reconnect becomes
much easier to reason about, and no patched dependency is required.

### Recommendation

**Use unmodified official librespot as the target architecture, but do not switch the
branch before refactoring reconnect.**

This project values compact, readable, robust code more than perfectly seamless audio
through every outage. Rebuilding and rehydrating one coherent generation is a better
tradeoff than preserving the Player across sessions, patching Spirc event correlation,
and maintaining the extra recovery/watchdog paths that follow from it.

The practical decision is:

- **Short term:** keep the current small patch while implementing P0.1 and making
  restart generation-safe.
- **Next:** replace soft reconnect with deterministic full rebuild + rehydration and
  run the outage/transfer test matrix.
- **Then:** pin Spotifly to an official librespot commit/release and delete the custom
  branch requirement.

If the remaining behavioral commit is accepted upstream first, switching can happen
earlier, but P0.1 and P0.2 still need fixing because they are integration-layer
problems rather than missing upstream APIs.

## Priority 0 — fix before further reconnect tuning

### P0.1 `SessionConnected` / `SessionDisconnected` have the wrong meaning at the boundary

**Finding**

The patched librespot emits these events when the local Connect device becomes active
or inactive:

- [`SpircTask::handle_activate`](../librespot/connect/src/spirc.rs) emits
  `SessionConnected`.
- [`SpircTask::handle_disconnect`](../librespot/connect/src/spirc.rs) emits
  `SessionDisconnected`.
- A normal cluster update that makes another device active calls
  `handle_disconnect`.

Spotifly handles `PlayerEvent::SessionDisconnected` as a failed network session:
it marks the connection disconnected and starts the Rust reconnect loop
([`rust/src/lib.rs`](rust/src/lib.rs), around lines 1491-1515). Swift also describes
the FFI callbacks as dealer connection changes
([`SpotifyPlayer.swift`](Spotifly/SpotifyPlayer.swift), around lines 396-425).
The forwarding is asymmetric: the activation event is forwarded to Swift
immediately, while the disconnected callback used by Swift's watchdog is sent only
after the Rust reconnect loop exhausts all attempts
([`LoggedInLifecycleModifier.swift`](Spotifly/Views/LoggedInLifecycleModifier.swift),
around lines 67-88; [`rust/src/lib.rs`](rust/src/lib.rs), around lines 921-937).

**Impact**

An ordinary playback transfer or another Spotify client becoming active can be
mistaken for a network outage. Depending on event ordering, Spotifly can:

- show a disconnected state while the underlying session is healthy;
- start an unnecessary reconnect;
- refresh from the Web API at the wrong time;
- reactivate itself and interfere with the intended device handoff.

This is a normal usage path, not a rare edge case.

**Small fix**

- Rename/reinterpret these events as `became_active` and `became_inactive`.
- Use them only to update active-device/playback routing state.
- Start network recovery only from actual transport evidence already available in
  Rust: an invalid `Session`, a closed cluster/dealer stream, or failure to create
  Spirc.
- Drive Swift's connection UI and reconnect transition handling from the existing
  full connection-state callback, not the activation callbacks.

The two session callbacks can then be removed from the Swift lifecycle layer. This
both fixes the bug and makes the bridge smaller.

### P0.2 Swift hard reinitialization can race Rust automatic reconnect

**Finding**

Rust starts a detached reconnect loop guarded only by the `RECONNECTING` atomic
([`rust/src/lib.rs`](rust/src/lib.rs), around lines 761-938). Swift's
`SpotifyPlayer.initialize` always calls `spotifly_cleanup` before
`spotifly_init_player` ([`SpotifyPlayer.swift`](Spotifly/SpotifyPlayer.swift), around
lines 688-723).

`spotifly_cleanup` clears the current player/session, but it does not cancel or
invalidate an already-running reconnect loop, clear `PENDING_TOKEN`, or reset
`RECONNECTING` ([`rust/src/lib.rs`](rust/src/lib.rs), around lines 2388-2463).
The old loop can therefore wake later and clean up or replace a newly initialized
session.

There are several ways to enter this overlap:

- the Swift watchdog calls `forceReinitialize`;
- wake handling always calls `forceReinitialize`;
- `disconnect()` is fire-and-forget on a detached Swift task, so wake initialization
  can begin before sleep disconnection has finished;
- multiple `forceReinitialize` / `initializeIfNeeded` calls can overlap across
  `await` points despite `@MainActor`.

**Impact**

This can produce exactly the reported symptom: Rust has moved to a new generation
while Swift still observes or mutates state associated with another one. It can also
leave `isInitialized` true after the active Rust objects have been replaced.

**Small fix**

Give lifecycle mutation one owner:

- Keep normal retry and short-outage recovery in Rust.
- Expose one `restart` operation for Swift's manual recovery/wake path. Inside Rust,
  it must invalidate the previous reconnect generation before cleaning up and
  rebuilding.
- Make every reconnect-loop iteration check that generation before sleeping ends,
  before cleanup, and before installing a new session.
- On the Swift side, deduplicate initialization/restart with one stored `Task`.

A generation cancellation check is sufficient; a general cancellation framework is
not necessary. `spotifly_cleanup` should remain an internal implementation detail or
be reserved for final logout/shutdown.

## Priority 1 — high-value robustness and state correctness

### P1.1 Initialization reports success before usable readiness is established

**Finding**

`PlaybackViewModel` sets `isInitialized = true` immediately after the FFI initializer
returns, then polls `isSpircReady` for five seconds but ignores timeout
([`PlaybackViewModel.swift`](Spotifly/ViewModels/PlaybackViewModel.swift), around
lines 142-186).

Rust also has a fallback where Spirc initialization can fail, a basic session
connection can succeed, and `spotifly_init_player` still returns success even though
all Connect commands require `SPIRC` ([`rust/src/lib.rs`](rust/src/lib.rs), around
lines 1587-1612).

**Impact**

Swift can permanently believe the player is initialized while every useful playback
command fails. `initializeIfNeeded` will then refuse to try again.

**Small fix**

- Define ready as one authoritative condition: session connected **and** Spirc ready.
- Complete Swift initialization only after the connection snapshot reaches ready.
- Treat timeout or the basic-session fallback as initialization failure for this app,
  because Spotifly's controls depend on Spirc.
- Replace the independent `isInitialized` flag with the authoritative readiness value,
  or at minimum set it only after readiness succeeds.

### P1.2 Most command results are discarded

**Finding**

The C API has useful typed results (`ok`, general error, needs reinit, not connected),
but most Swift wrapper methods launch a detached task and ignore the result
([`SpotifyPlayer.swift`](Spotifly/SpotifyPlayer.swift), around lines 909-1089).
Some view-model methods optimistically change position or playing state even when
Rust can reject the command during a reconnect
([`PlaybackViewModel.swift`](Spotifly/ViewModels/PlaybackViewModel.swift), around
lines 278-438 and 660-685).

**Impact**

During a short outage, Swift can say pause/seek/next succeeded while Rust rejected it.
The UI may eventually correct itself from a later callback, but until then the two
sides visibly disagree. Media-key handlers also return success before knowing whether
the command was accepted.

**Small fix**

- Add one small Swift helper that executes an FFI command and maps
  `SpotiflyResult`.
- Return success/failure from the wrapper instead of discarding it.
- Change presentation state only after command acceptance or, preferably, the Rust
  state callback.
- On `sessionNotConnected`, show/retain the last confirmed state and let the existing
  reconnect loop recover. Do not build a retry queue for every command.

If one retry is desired, limit it to the latest explicit play/pause intent after the
connection becomes ready. Retrying seek, next, volume, and queue edits later can
produce surprising actions and is not worth the added machinery.

### P1.3 Active-device state has two competing sources of truth

**Finding**

Rust maintains `IS_ACTIVE_DEVICE` through selected local events and command paths.
Separately, the cluster listener sends `active_device_id` to Swift, which updates
`AppStore`. `PlaybackViewModel` chooses Spirc versus Web API using the Rust atomic,
while views use the store's device data.

The cluster listener does not set `IS_ACTIVE_DEVICE` by comparing the cluster's active
device ID with Spotifly's own device ID
([`rust/src/lib.rs`](rust/src/lib.rs), around lines 706-718). Empty active-device IDs
are also ignored, leaving the previous value in Swift.

**Impact**

Controls and UI can disagree about whether Spotifly or a remote speaker is active,
especially around external transfers and inactive/no-playback states.

**Small fix**

On every cluster update, compute local activity once:

```text
is_active = cluster.active_device_id == own_device_id
```

Store that in Rust and include it in the same connection/state snapshot sent to
Swift. Allow an empty active-device ID to clear the state. Playback routing and views
should read this same fact.

### P1.4 A stale Web API response can overwrite a newer Rust callback

**Finding**

`fetchInitialPlaybackState` fetches playback and queue data and applies both
unconditionally when the requests complete
([`QueueService.swift`](Spotifly/Store/Services/QueueService.swift), around lines
262-323). Rust queue/playback callbacks can arrive while those network requests are
in flight. The fixed delay after a locally initiated transfer reduces one known race,
but it is not a general freshness rule.

**Impact**

After reconnect or transfer, Swift can briefly receive the correct live Rust state
and then replace it with an older Web API snapshot. This is likely to look like Swift
"does not know" Rust's state.

**Small fix**

Maintain two small monotonically increasing Swift-side revisions, one for playback
and one for the queue:

- increment the relevant revision whenever its Rust callback is accepted;
- capture both before starting the Web API bootstrap request;
- apply each part of the Web API result only if its corresponding revision has not
  changed.

This is a few lines of state and avoids timestamps, cancellation trees, and arbitrary
additional delays.

## Priority 2 — simplification and maintainability

### P2.1 Connection snapshots need an ordering field

**Finding**

Connection snapshots are built from several independent mutexes and atomics, then
callbacks can originate from different Rust tasks. Swift's `CurrentValueSubject`
accepts whichever callback arrives last, but the payload has no generation or
sequence number.

**Impact**

During cleanup/reconnect, a delayed callback from an older session can overwrite a
newer state. Independent reads can also briefly form combinations such as ready from
one transition and connection metadata from another.

**Small fix**

Keep the connection fields together in one mutex-protected `ConnectionStateInfo`
instead of reconstructing it from independent globals. Add `generation` and
`revision`, increment the revision for each published transition, and have Swift
ignore snapshots older than the last accepted `(generation, revision)`. This also
makes reconnect logs much easier to reason about.

Do not add acknowledgements or per-event IDs; one pair on the authoritative snapshot
is enough.

### P2.2 The FFI parsing and callback surface is larger than necessary

**Finding**

Connection JSON is parsed twice in Swift with duplicated permissive dictionary code:
once in the callback and once in `getConnectionState`. Missing or renamed fields
silently become plausible defaults such as `false`, `0`, or an empty string.
`StateUpdateCallback` is also registered and emitted, but its Swift handler only logs
the event.

**Impact**

Schema drift looks like a real disconnected/empty state instead of an integration
error. Dead callbacks make it harder to see which events actually drive state.

**Small fix**

- Decode each payload through one shared `Decodable` function.
- Log and reject malformed required fields rather than manufacturing state.
- Remove `StateUpdateCallback` unless it is wired to a real consumer.
- After P0.1, remove the redundant session connected/disconnected callbacks as well.

This reduces code while making failures more explicit.

### P2.3 Callback delivery should enter Swift through one serialized lane

**Finding**

Several global Combine subjects are marked `nonisolated(unsafe)` and are sent directly
from Rust callback threads. Some callbacks first hop to `@MainActor`, while others
rely on each subscriber's `.receive(on:)`.

**Impact**

The split policy makes ordering difficult to reason about and leaves thread safety to
global unsafe state.

**Small fix**

Have every non-audio callback enter one serial Swift executor before updating the
bridge snapshot/publishers. `@MainActor` is adequate because these payloads are small.
Keep audio callbacks on their dedicated real-time-safe path.

If the versioned snapshot from P2.1 is implemented, exact task scheduling order is no
longer correctness-critical.

## Tests worth adding

There are currently no focused lifecycle/integration tests in the Rust library, and
the Swift tests do not cover the bridge. A small deterministic suite would provide
more value than more reconnect branches:

1. A device becoming inactive does not start network reconnection.
2. A closed cluster/session transport starts exactly one reconnect loop.
3. Manual restart invalidates an older sleeping reconnect generation.
4. Initialization does not succeed without Spirc readiness.
5. A Rust callback arriving during Web API bootstrap prevents the stale response from
   being applied.
6. A rejected command does not optimistically change confirmed Swift state.

These can test extracted transition/revision logic without connecting to Spotify.
End-to-end outage tests are useful later, but they should not be required to make the
core state rules deterministic.

## Recommended compact ownership model

| Concern | Owner | Rule |
| --- | --- | --- |
| Session, Spirc, reconnect, generation | Rust | Only Rust creates/replaces librespot objects |
| Connect activity, playback facts, queue URIs | Rust snapshot | Push every meaningful change with generation/revision |
| UI state, interpolation, metadata cache | Swift | Derived from the latest accepted Rust snapshot |
| Initial remote state | Web API | Apply only if no newer Rust revision arrived |
| Command feedback | Swift wrapper | Preserve the typed Rust result; do not silently assume success |

Avoid adding `NWPathMonitor`, periodic reconnect polling, a command journal, or more
fixed delays. The current problems are ownership and ordering problems; those tools
would add code without resolving the ambiguity.

## Suggested implementation order

1. Correct activation-vs-connection event semantics (P0.1).
2. Make restart/reconnect generation-safe and serialize Swift initialization (P0.2).
3. Make readiness authoritative and preserve command results (P1.1-P1.2).
4. Unify active-device truth and add the Web API freshness barrier (P1.3-P1.4).
5. Add snapshot ordering, consolidate parsing, and delete dead callbacks
   (P2.1-P2.3).
6. Replace soft reconnect with full rebuild + rehydration, verify the outage matrix,
   and pin an unmodified official librespot revision.

After steps 1-4, reassess the remaining code. Several existing watchdogs, polls, and
special-case comments should become removable rather than needing further tuning.
