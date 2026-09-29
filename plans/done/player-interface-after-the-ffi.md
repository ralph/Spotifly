# The player's interface to the app is still shaped like the FFI it replaced

Status: **Done** 2026-09-28 (#71). The two places where the player waited on the main thread
were fixed on 2026-09-27 (`5c00231`).
Components: `Spotifly/SpotifyPlayer.swift`, `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`,
`Spotifly/Store/PlayerModel.swift`, and what subscribed to them: `PlaybackViewModel`,
`QueueService`, `DeviceService`, `ConnectionService`, `LoggedInLifecycleModifier`
Found: when #65 removed the FFI

## Summary

With the Rust layer gone, the player still talked to the app in the shape the FFI had given
it: ten Combine subjects, several of them one fact under different names, and types carrying
FFI residue. The client now yields ordered snapshots to one `@Observable` `PlayerModel`, with
no Combine between the player and the UI. A slow UI cannot interrupt playback. Apart from the
two main-thread waits, this was a refactor with no behaviour change intended.

## Problem

### Can a slow UI interrupt playback?

No, by construction. Where the audio lives:

| Stage | Runs on | Holds |
| --- | --- | --- |
| Output | Core Audio's real-time I/O thread, pulling from `AVSampleBufferAudioRenderer` | 1–1.9 s |
| Decoding | the `AudioPipeline` actor, suspended in `AudioRenderer.enqueue` until the renderer wants more | — |
| Loads, position, end of track | the `AudioPipeline` actor, on the cooperative pool | the next track, once fetched ahead |
| Connect, network | `LibrespotClient`, `LibrespotSession`, `SpircController`, `DealerConnection`, `Accesspoint`, `SPClient`, all actors | — |

One to two seconds of decoded audio sit in the renderer at any time, and nothing on the audio
path waits for the main thread. The UI reads the player's state through cached values that never
block (`SpotifyPlayer.positionMs`, `isPlaying`, `isActiveDevice`), and its commands are
fire-and-forget tasks. Auto-advance and gapless continuation are actor-driven, so a frozen UI
does not stop the next track either.

Two places did wait for the main thread, and were fixed in `5c00231`:

- `SpircController` sent every dealer push — remote commands and cluster updates — through
  `Task { @MainActor … }` before its own actor handled it, a hop from the module's first
  scaffold (`eb35bdb`) with no stated reason. A remote pause waited for whatever SwiftUI was
  doing. Now an `AsyncStream` consumed inside the actor, which also keeps the pushes in order.
- `applyPlaybackSettings` read `SpotifyPlayer.gapless`, which was main-actor isolated.

What is left is shared rather than coupled. The actors run on the same cooperative pool as the
UI's own async work, so CPU-heavy work parked there (image decoding, large JSON) can delay the
pipeline's 250 ms tick, and decoding itself now runs on that pool too, a tenth of a
millisecond per chunk. With a second or more queued in the renderer, a delay has to last that
long to be heard, and a gapless handover needs the tick within about a second of the decode
finishing.

### What the interface looks like now

`SpotifyPlayer.swift` says it itself: "Every type here is the same shape it was across the FFI,
so services and views needed no changes." The migration was right to keep it for the port.
Keeping it now carries these costs:

- **Ten Combine subjects on `LibrespotClient`**, re-exported one by one as static properties,
  several of them one fact under different names. `queue` and `setQueue` carry the same queue
  twice, the second with the context uri and its own `SetQueueTrackInfo` copy of `QueueItem`.
  Whether this device is active is published as `becameActive`, `becameInactive`,
  `activeDeviceChanged`, `connectionState.isActiveDevice` and `isActiveDeviceFlag`;
  `becameActive` and `becameInactive` have no subscribers at all.
- **Types with FFI residue.** `LibrespotConnectionState` is `Codable` with snake_case keys
  nothing decodes. Its `revision` orders snapshots that arrive in order and is read nowhere,
  and its doc points at a `deliverConnectionState` that no longer exists.
  `sessionConnectionId` is always nil, and `spircReady` always equals `sessionConnected`, so
  the connection status shows one fact as two rows. Volume crosses as a `UInt16` of 0–65535, the
  Connect wire format, and is divided back into 0–1 by the one subscriber. Positions cross as
  `Int64` and are narrowed defensively on arrival. The provider is a `String`, repeat is two
  `Bool`s, and `ForceReconnectOutcome` is declared twice and mapped case by case.
- **Every subscriber has to remember `.receive(on: DispatchQueue.main)`.** Eleven do. Two
  comments record what happened when one did not: `DeviceService` trapped on the first real
  cluster, and `LoggedInLifecycleModifier`'s `.onReceive` wrote SwiftUI state off the main
  thread. Combine also delivers every intermediate value, so a main thread that stalls works
  through a backlog of stale states afterwards.
- **Race-prone reads.** `positionCache` and `isActiveDeviceFlag` are `nonisolated(unsafe)`
  vars, written on an actor and read from the main thread: a data race by Swift's rules,
  benign on arm64 in practice.
- **Unordered hops inside the engine.** Each pipeline event and each remote command reaches
  `LibrespotClient` through `sink { Task { await self.handle(…) } }`, one unstructured task per
  event, so two events sent back to back are not guaranteed to be handled in that order.
- **Commands swallow their errors.** `SpotifyPlayer.next()`, `previous()`, `seek()` and
  `playRadio()` are `Task { try? await … }`, so the UI cannot tell a skip that failed from one
  that worked.

## Solution

### Proposal

Five steps, each shippable on its own, in order of value per risk.

1. **Delete the residue.** `becameActive` and `becameInactive`; `revision`, `Codable` and
   the `CodingKeys` of `LibrespotConnectionState`; `sessionConnectionId`; `spircReady`, or else
   have it mean something; the second `ForceReconnectOutcome`; `SetQueueTrackInfo`. Put
   `contextUri` on `QueueState` and drop the `setQueue` publisher. No behaviour change.
2. **Make the cached reads race-free** with `Mutex` from `Synchronization`, which also replaces
   the hand-rolled `Flags` class and its `NSLock`.
3. **Order the engine's own events.** One `AsyncStream<AudioPipeline.Event>` (state, end of
   track, error) with a single consumer loop in `LibrespotClient` instead of a `sink` and a
   task per event, and the same for the session's cluster updates. Remote commands need a
   decision first: consumed one at a time, a play that is still loading holds up the next
   command, where today a second Next supersedes the first through the pipeline's load
   generation. Keep them concurrent, or consume them serially and let a new load cancel the
   old one explicitly.
4. **One observable model at the UI boundary.** A `@MainActor @Observable final class
   PlayerModel` holding what the UI reads — connection, devices, active device id, playback,
   queue with its context, volume as 0–1 — fed by one task on the main actor that consumes the
   engine's snapshots:

   ```swift
   for await snapshot in client.snapshots {   // AsyncStream, bufferingPolicy: .bufferingNewest(1)
       model.apply(snapshot)
   }
   ```

   The engine only ever yields, so it never waits for the main thread. The buffering policy
   decides what a slow UI sees: the newest state, not a backlog of every state in between.
   Views read the model and Observation tracks exactly what each one reads, so no service
   needs a subscription, a cancellable or a main-queue hop, and transitions such as "became
   active" are comparisons in `apply`, not publishers. The static facade becomes the client
   itself, injected through the environment, with `async throws` commands; that also makes
   a fake player possible for tests. Migrate one consumer at a time: `ConnectionService`,
   `DeviceService`, `QueueService`, and `PlaybackViewModel` last. It is the largest (1,635
   lines), and only the inputs to its position anchoring would change.
5. **The macOS 27 renderer API** — done on 2026-09-27, with the deployment target raised to
   27.0. `AVSampleBufferAudioRenderer.Receiver.enqueue(_:) async` suspends until the
   renderer wants more; the decode loop is a task that awaits it, and the ring buffer, the
   write throttle, the feed callback, the decode thread and the pause park are gone. See
   `docs/cpu-benchmark.md`, "Feeding the renderer".

### How it landed

The sections above describe the code as it was before steps 1–4.

1. **Residue.** All of it went, as listed. `spircReady` was deleted rather than given a
   meaning, and its row on the connection dashboard went with it. The provisional-SetQueue
   refresh in `QueueService` went too. It covered the Rust path, and could never have helped,
   because the `QueueState` sent just before had already applied the empty queue.
2. **Race-free reads.** `positionCache`, the active-device flag and `Flags` are behind
   `Mutex`. The active-device flag was later folded into the snapshot (step 4).
3. **Ordered events.** The pipeline sends state, position, end of track and errors on one
   `AsyncStream`, and the session sends its state, Spirc's clusters and its commands on another.
   Each has one consumer loop in `LibrespotClient`. The decision on remote commands: they
   stay concurrent, each in its own task as before, but the tasks now start in the order the
   commands arrived. Handling them one at a time would hold a Next behind a play that is still
   loading, where the pipeline's load generation already lets the Next supersede it.
4. **One observable model.** `PlayerModel` (`Store/PlayerModel.swift`) applies
   `PlayerSnapshot`s that the client yields on an `AsyncStream` with `.bufferingNewest(1)`.
   The same snapshot, behind a `Mutex`, serves the facade's synchronous reads. Where the result
   differs from the proposal:
   - **Two consumers still observe**, because they have side effects rather than a view to
     draw. `QueueService` projects the queue into the store and loads metadata, and
     `PlaybackViewModel` anchors the position and publishes Now Playing. Both use
     `Observations` on the model, on the main actor, with no Combine and no hop.
     `ConnectionService` is gone. `DeviceService` is down to transfers, and the store no
     longer holds devices or the connection.
   - **The facade stays static for commands.** It carries more than the client (the
     renderer, the settings, the streaming grant, transfers). A fake player would need a
     protocol over all of it, for tests that do not exist yet. The model is what views get
     from the environment, and `PlayerModelTests` drive it with snapshots, no engine needed.
   - **Commands report failures.** `next`, `previous`, `seek` and `playRadio` are
     `async throws`, and local and remote transport commands share one error path. The
     view model's `errorMessage` is still shown nowhere, so failures reach the log but not
     the screen.
   - **The loading notification went.** Every one of them either went out beside an
     optimistic playback state naming the same track and position, or anchored the position
     at zero until the next state corrected it.
   - **Not done:** positions still cross as `Int64`, the provider as a `String`, and
     repeat as two `Bool`s.

Two bugs came to light while doing this, and were fixed:

- The dashboard's uptime went back to zero on every cluster update, because each update
  republished the connection state with a fresh connect time.
- A device the store marked active lost its `disableVolume` flag.

## Verification

This plan records no live run of its own. `PlayerModelTests` drive the model with snapshots,
with no engine. The two bugs found along the way are under *How it landed*.
