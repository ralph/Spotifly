# Librespot Integration Review

Review date: 2026-07-30

Scope: static review of the current Swift app, C FFI, Rust wrapper, and the
`spotifly-dev` librespot sources. No live Spotify session or forced-outage test was
run as part of this review.

### Verification status

A second pass on 2026-07-30 re-checked every finding below against the code.
P0.1, P0.2, P1.1, P1.3, P1.4, P2.1, P2.2, P2.3, the four-file fork delta, the
upstreaming claims, and the "no tests" claim were all confirmed. That pass also
corrected two claims (event-source attribution in P0.1, scope of P1.2), added P0.3
and the dependency-pin gap below, and is marked inline where relevant.

One claim was **not** re-verified: the `cargo check` result against an exported copy
of official `dev` (see "Compatibility check"). It is carried forward on trust.

## Executive summary

The integration has the right building blocks: Rust pushes playback and connection
updates, Swift can pull an initial snapshot, Rust retries short network failures with
backoff and fresh tokens, and a generation protects against stale cluster listeners.

One caveat on that last point: only the **cluster** listener's generation check
actually works. The player event listener's equivalent check is dead code — see P0.3.

The brittleness comes mainly from overlapping meanings and recovery owners:

- librespot's **upstream** (not patched) `SessionConnected` and `SessionDisconnected`
  player events describe Spotify Connect device activation, but Spotifly treats them
  as network session health.
- Rust owns automatic reconnect, while Swift can concurrently tear everything down
  and initialize it again.
- Swift combines Rust callbacks, synchronous Rust polling, optimistic UI changes,
  and Web API snapshots without a freshness rule.

The smallest robust direction is:

1. Let Rust be the sole owner of the librespot lifecycle and reconnect loop.
2. Publish one authoritative, versioned Rust snapshot to Swift.
3. Treat Web API state as bootstrap/fallback data only.
4. Make command acceptance visible instead of discarding every FFI result.

This does not require a general retry framework or handling every theoretical edge
case. It is, however, honest to call the result a state machine: generation/revision
on snapshots, a readiness predicate, two Swift revision counters, and a restart
generation protocol add up to one — just a small and explicit one, distributed across
the bridge. The goal is to make the existing implicit state machine legible, not to
avoid having one.

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

Both `handle_next` ([`spirc.rs:1722`](../librespot/connect/src/spirc.rs)) and
`handle_prev` ([`spirc.rs:1763`](../librespot/connect/src/spirc.rs)) use
`play_status.is_playing()` in the fork, so the local-play-intent fix is complete.
`docs/network-session-stability-plan.md` (lines 52 and 120) still lists the
`handle_prev` half as outstanding — that item is done and should be ticked off.

### The two patches are not equally disposable

They should be tracked separately, because only one of them is tied to Spotifly's
lifecycle choices:

- **`play_request_id` adoption** exists *only* because soft reconnect retains the
  Player across sessions. It disappears when soft reconnect does.
- **`play_status.is_playing()`** is an upstream bug fix independent of Spotifly's
  lifecycle: remote-facing `ConnectState` lags during `LoadingPlay`, so next/previous
  can load the following track paused even with no reconnect involved. Nothing in the
  refactor below removes the need for it.

Consequently, "no patched dependency is required" holds only if the `is_playing()`
commit lands upstream. That commit is worth submitting **now**, independently of the
reconnect work, rather than waiting on the refactor. When rebuilding `spotifly-dev`
as a clean branch, split it into these two commits so they can be reasoned about and
upstreamed separately.

### No dependency pin exists today

[`rust/Cargo.toml`](rust/Cargo.toml) (lines 11-17) uses local **path** dependencies:

```toml
librespot-core = { path = "../../librespot/core" }
librespot-connect = { path = "../../librespot/connect" }
librespot-playback = { path = "../../librespot/playback" }
librespot-protocol = { path = "../../librespot/protocol" }
```

There is no branch or revision pin anywhere. The build resolves to whatever happens to
be checked out in `../../librespot`, so builds are not reproducible and
`CONTRIBUTING.md`'s "use the `spotifly-dev` branch" is an unenforced convention.

This has already had an effect: the stale build artifact
`rust/target/aarch64-apple-darwin/release/libspotifly_rust.d` lists
`librespot/.git/refs/heads/use-local-is-playing-state` among its inputs, meaning a
previous build was produced from a different branch than the documented one.

Converting these to `git` + `rev` dependencies is therefore its own work item, and a
prerequisite for the "pin an official revision" step in the implementation order —
not something that falls out of it. Note that discussions of "switching the dependency
branch" below are shorthand: today there is no branch reference to switch.

### Compatibility check

The current, unmodified Spotifly Rust wrapper passes `cargo check` against an exported
copy of official `dev` at commit `9c7d75615fc093bdcbdb29adbce3fed38c531852`.
This proves source/API compatibility, including queue APIs. It does not prove runtime
reconnect behavior.

The latest local release tag is `v0.8.0`; official `dev` is 16 commits newer and
contains the queue APIs Spotifly uses. Therefore a migration today should pin the
tested official commit (or a later official release containing those commits), not
silently use the older `v0.8.0` sources and not track a moving branch.

Confirmed present in official `dev`: `Spirc::add_to_queue`, `PlayerEvent::SetQueue`,
`ConnectConfig::emit_set_queue_events`, `QueueTrack`, and `Player::set_session`. Note
that "pin" here describes work still to be done — see "No dependency pin exists today"
above; nothing is pinned at present.

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
- The branch history obscures that only two meaningful changes remain, currently
  squashed into one commit.

If this option is kept temporarily, rebuild `spotifly-dev` on top of official `dev` as
**two** clean commits — `play_status.is_playing()` and `play_request_id` adoption —
rather than carrying the historical 38-commit chain, and submit the `is_playing()`
commit upstream. Splitting them matters because only the second one goes away when soft
reconnect does.

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
Player and Spirc lifetimes match official librespot's normal model and reconnect
becomes much easier to reason about.

This removes the need for the `play_request_id` patch, but **not** for
`play_status.is_playing()` — that one fixes an upstream lag between local play intent
and remote-facing `ConnectState` that has nothing to do with Spotifly's session
lifetime. Running fully unpatched therefore requires that commit to be accepted
upstream first; until then this option reduces the fork to one commit rather than
eliminating it.

### Recommendation

**Use unmodified official librespot as the target architecture, but do not switch the
branch before refactoring reconnect.**

This project values compact, readable, robust code more than perfectly seamless audio
through every outage. Rebuilding and rehydrating one coherent generation is a better
tradeoff than preserving the Player across sessions, patching Spirc event correlation,
and maintaining the extra recovery/watchdog paths that follow from it.

The practical decision is:

- **Now:** submit the `play_status.is_playing()` commit upstream. It is independent of
  everything else here and is on the critical path for dropping the fork.
- **Short term:** keep the current patch while fixing the generation check (P0.3),
  correcting event semantics (P0.1), and making restart generation-safe (P0.2).
- **Next:** replace soft reconnect with deterministic full rebuild + rehydration and
  run the outage/transfer test matrix.
- **Then:** convert the path dependencies to `git` + `rev`, pin an official librespot
  commit/release, and delete the custom branch requirement.

If the `is_playing()` commit is accepted upstream first, switching can happen earlier,
but P0.1, P0.2, and P0.3 still need fixing because they are integration-layer problems
rather than missing upstream APIs. P0.1 in particular is unaffected by the choice of
librespot revision: those events carry activation semantics in official `dev` too.

## Priority 0 — fix before further reconnect tuning

### P0.1 `SessionConnected` / `SessionDisconnected` have the wrong meaning at the boundary

**Finding**

These events are **upstream librespot behavior, not part of the fork.** They are
defined and emitted in [`playback/src/player.rs`](../librespot/playback/src/player.rs)
(variants at lines 237/241, emission at 2353-2364); `spirc.rs` calls the
`emit_session_*_event` helpers. `git show dev:connect/src/spirc.rs` contains the
identical calls at lines 1300 and 1318, and neither file appears in the four-file fork
delta. Returning to official librespot therefore does **not** change or fix any of
this — P0.1 is entirely an integration-layer problem.

librespot emits them when the local Connect device becomes active or inactive:

- [`SpircTask::handle_activate`](../librespot/connect/src/spirc.rs) (line 1319) emits
  `SessionConnected`.
- [`SpircTask::handle_disconnect`](../librespot/connect/src/spirc.rs) (line 1293) emits
  `SessionDisconnected`.
- A normal cluster update that makes another device active calls `handle_disconnect`
  ([`spirc.rs:1003-1008`](../librespot/connect/src/spirc.rs)).

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

**The concrete worst case is where this compounds with P1.4.**
[`LoggedInLifecycleModifier.swift`](Spotifly/Views/LoggedInLifecycleModifier.swift)
(lines 67-76) reacts to the *activation* event by calling
`queueService.fetchInitialPlaybackState`. Because activation is not connection (P0.1)
and the Web API bootstrap has no freshness barrier (P1.4), every device handoff fires
an unguarded full Web API refetch that can overwrite live Rust state. This specific
pair — activation event triggering an unversioned Web API bootstrap — is the most
likely explanation for the reported symptom that Swift "does not know" Rust's state,
and it is fixed by P0.1 and P1.4 together.

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

Note that the generation primitive P0.2 wants to build on is currently broken — see
P0.3, which should be fixed first.

### P0.3 The player event listener's stale-generation check can never fire

**Finding**

The `SessionDisconnected` handler guards against events from an old session
([`rust/src/lib.rs`](rust/src/lib.rs), lines 1491-1504):

```rust
let my_gen = EVENT_LISTENER_GENERATION.load(Ordering::SeqCst);
let current_gen = SESSION_GENERATION.load(Ordering::SeqCst);
if my_gen != current_gen { /* ignore stale event */ continue; }
```

`EVENT_LISTENER_GENERATION` is written in exactly two places — lines 1088 and 1287 —
and both write the value just produced by `SESSION_GENERATION.fetch_add(..) + 1`. The
two globals are therefore always equal, so `my_gen != current_gen` is false in steady
state and the ignore branch is unreachable. The only window where they differ is
between the `fetch_add` and the following `store`, during which the check discards
events from the *current* session rather than an old one.

The listener does capture a correct per-generation local
(`event_listener_generation`, line 1289), but it is used only for logging (line 1295).
Reading the global instead was deliberate — the comment at lines 165-167 explains it
lets soft reconnect update the generation without replacing the listener — but the
consequence is that the check lost its ability to reject anything.

By contrast, the cluster listener's check is genuine: `spawn_cluster_listener` takes
`generation` as a parameter (line 697) and compares that captured value against
`SESSION_GENERATION` (line 728).

**Impact**

This removes the protection P0.2 depends on. On a hard reconnect a new event listener
is spawned while the old one is signalled asynchronously through the previous
`PLAYER_EVENT_TX`. Until the old listener drains and exits, it can still deliver a
`SessionDisconnected` — and because the check compares two always-equal globals, that
event passes and calls `spawn_reconnection_loop()` against the new generation. The
"generation protects against stale listeners" property that the rest of this review
assumes does not hold for player events.

**Small fix**

Compare against the captured local rather than the global:

```rust
if event_listener_generation != SESSION_GENERATION.load(Ordering::SeqCst) { continue; }
```

Soft reconnect then needs to hand the surviving listener its new generation
explicitly — either by replacing the listener along with the session, or by moving the
generation into an `Arc<AtomicU64>` owned by that listener alone, so updating it stays
a deliberate act rather than a side effect of any session bump. This is a one-line
correctness fix plus a small ownership decision, and it should land before P0.2 so the
restart work has a working invalidation primitive.

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

The C API has useful typed results (`ok`, general error, needs reinit, not connected —
[`spotifly_rust.h`](rust/include/spotifly_rust.h), lines 38-43), but most Swift wrapper
methods launch a detached task and ignore the result
([`SpotifyPlayer.swift`](Spotifly/SpotifyPlayer.swift), around lines 909-1089).

The view-model side is better than it first appears, and the scope here is narrower
than originally written. `next()`, `previous()`, `pause()`, `resume()`, and
`toggleShuffle()` all already `guard SpotifyPlayer.isSessionConnected else { return }`
before calling into Rust, and that guard returns *before* the optimistic position
reset, so nothing is applied on the rejected path. `pause()` deliberately leaves
`isPlaying` alone and waits for the Mercury callback.

The genuine exception is **seek**:
[`seek(to:)`](Spotifly/ViewModels/PlaybackViewModel.swift) (lines 361-370) writes
`positionAnchorMs`/`currentPositionMs` immediately, and the debounced
[`performSeek`](Spotifly/ViewModels/PlaybackViewModel.swift) (lines 671-685) is the one
command path with no connectivity guard at all.

**Impact**

During a short outage Swift can report a seek that Rust rejected. The coarse
`isSessionConnected` pre-check covers the common `sessionNotConnected` case for the
other commands, but it cannot see general errors or `sessionDisconnected` (-1/-2), so
those still pass silently everywhere. Media-key handlers also return `.success` before
knowing whether the command was accepted
([`PlaybackViewModel.swift`](Spotifly/ViewModels/PlaybackViewModel.swift), lines
475-531).

Because of the existing guards, this is a smaller correctness problem than P0.1-P0.3 —
worth fixing for the typed-result plumbing and to close the seek hole, but it is not
the cause of the reported state divergence.

**Small fix**

- Add one small Swift helper that executes an FFI command and maps
  `SpotiflyResult`.
- Return success/failure from the wrapper instead of discarding it.
- Give `performSeek` the same `isSessionConnected` guard the other commands have, and
  do not move the anchor until the seek is accepted.
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
are also ignored in `notify_active_device_id` (lines 583-586), leaving the previous
value in Swift. `IS_ACTIVE_DEVICE` is instead written from roughly eighteen scattered
command and event sites.

**Root cause: the subscription is duplicated**

`spawn_cluster_listener` (line 697) subscribes to `hm://connect-state/v1/cluster` —
the exact dealer topic `SpircTask` already subscribes to
([`spirc.rs:187`](../librespot/connect/src/spirc.rs)). There are two independent
consumers of one topic, each maintaining its own notion of which device is active.
That duplication, not the missing comparison, is why there are two sources of truth.

librespot also already computes precisely the comparison proposed below, at
[`spirc.rs:1003-1004`](../librespot/connect/src/spirc.rs):

```rust
let became_inactive = self.connect_state.is_active()
    && cluster.active_device_id != self.session.device_id();
```

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

Be aware that this fix *keeps* the duplicate subscription and simply makes the second
consumer agree with the first. That is the smaller change and fine as a first step, but
the better end state is to stop maintaining a parallel cluster view at all and derive
activity from Spirc/`ConnectState`, which already tracks it. Prefer that if the P0.1
work ends up reshaping how activation reaches Swift anyway, since both touch the same
seam.

### P1.4 A stale Web API response can overwrite a newer Rust callback

**Finding**

`fetchInitialPlaybackState` fetches playback and queue data and applies both
unconditionally when the requests complete
([`QueueService.swift`](Spotifly/Store/Services/QueueService.swift), around lines
262-323). Rust queue/playback callbacks can arrive while those network requests are
in flight. The fixed delay after a locally initiated transfer reduces one known race,
but it is not a general freshness rule.

The Web API `timestamp` is threaded through to `applyWebAPIPlaybackState`
([`PlaybackViewModel.swift`](Spotifly/ViewModels/PlaybackViewModel.swift), lines
760-817), but it is used only to compensate the position anchor *within* the Web API
snapshot. It is never compared against anything Rust published, so it does not act as a
freshness barrier despite looking like one.

There are two callers, and the second matters more than the bootstrap:
`LoggedInLifecycleModifier` calls this both from initial `.task` setup (line 65) and
from the `sessionConnected` handler (line 74) — that is, on every device activation.
See P0.1.

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
4. A `SessionDisconnected` delivered by a superseded event listener is rejected and
   does not spawn a reconnect loop. **This test fails against the current code** (P0.3)
   and is the cheapest way to pin that fix.
5. Initialization does not succeed without Spirc readiness.
6. A Rust callback arriving during Web API bootstrap prevents the stale response from
   being applied.
7. A rejected command does not optimistically change confirmed Swift state, including
   the seek path specifically (P1.2).

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

1. Fix the player event listener's generation check (P0.3). One line, and it must come
   first: P0.2 builds a restart protocol on top of this primitive, and fixing P0.1
   first would make the racy path rare enough to hide that the primitive is broken.
2. Correct activation-vs-connection event semantics (P0.1).
3. Make restart/reconnect generation-safe and serialize Swift initialization (P0.2).
4. Make readiness authoritative and preserve command results (P1.1-P1.2).
5. Unify active-device truth and add the Web API freshness barrier (P1.3-P1.4).
6. Add snapshot ordering, consolidate parsing, and delete dead callbacks
   (P2.1-P2.3).
7. Replace soft reconnect with full rebuild + rehydration and verify the outage matrix.
8. Convert the librespot path dependencies to `git` + `rev` and pin an unmodified
   official revision. This is a real step, not a consequence of step 7 — today there is
   no pin at all. It is unblocked only once the `play_status.is_playing()` commit is
   upstream; submit that commit early and independently.

After steps 1-5, reassess the remaining code. Several existing watchdogs, polls, and
special-case comments should become removable rather than needing further tuning.
