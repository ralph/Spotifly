# AirPlay from Speakers without sending the Mac's other audio

Status: **Open**, 2026-10-03; draft proposal. Per-renderer output selection is supported;
initiating an idle AirPlay receiver with the current renderer is not yet verified.
Components: `Spotifly/Views/SpeakersView.swift`, `Spotifly/Views/AirPlayRoutePickerView.swift`,
`Spotifly/AudioRenderer.swift`, `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`, `Spotifly/SpotifyPlayer.swift`,
`Spotifly/Store/LoggedInSession.swift`, `Spotifly/ViewModels/AuthViewModel.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`, a proposed audio-output routing service,
localizations
Found: 2026-10-03, user request: AirPlay currently starts from macOS Control Center; the
Speakers section should start it for Spotifly's Spotify stream alone, without system sounds.
Updated: 2026-10-03, user identified "Küche HomePod" in Control Center as an AirPlay speaker
and prefers the latest AirPlay behavior; legacy support is not required.

## Summary

**The existing picker cannot directly route the existing renderer on macOS 27.**
`AVRoutePickerView.player` accepts an `AVPlayer`. The installed SDK explicitly limits its
sample-buffer-renderer support to iOS and tvOS. Spotifly uses an actor-owned
`AVSampleBufferAudioRenderer`, fed by its macOS 27 `Receiver.enqueue(_:) async` API.

**App-only output selection is possible when a usable Core Audio device exists.** Set the
renderer's `audioOutputDeviceUniqueID`, without changing either system default output.
However, selecting an existing device is not the same as discovering and connecting an idle
AirPlay receiver. No public bridge from the native picker to this renderer was found.

The recommended next step is a **hardware feasibility gate**, using public Core Audio
transport-manager and process-private endpoint-device APIs. **The current inventories
already meet its first fail condition: no AirPlay device or transport manager is exposed.**
Start with a cheap signed-app confirmation of that inventory, not the full playback probe.
There is no evidence that signing/sandboxing will expose more than the unsandboxed tool did.
If the same result holds, stop this approach. Only if an AirPlay manager and endpoints are
exposed does the remaining gate make sense. Product implementation remains conditional on
that gate passing; the investigation does not justify promising this feature or replacing
the renderer yet.

Target **modern AirPlay 2 through Apple's current macOS 27 stack**, with "Küche HomePod" as
the first test receiver. Prefer the newest behavior the native stack and receiver support.
Do not add an AirPlay 1/legacy RAOP fallback or support for older OS renderer APIs. A generic
HAL AirPlay output is not evidence that the connection uses the desired modern transport.

## Problem

### Current code

- [`AirPlayRoutePickerView`](../../Spotifly/Views/AirPlayRoutePickerView.swift) creates an
  `AVRoutePickerView` with no `player`. There is no association with the Spotify PCM stream.
- [`SpeakersView`](../../Spotifly/Views/SpeakersView.swift) already has an AirPlay section. Its
  enablement compares `activeDevice.name` with the literal `"Spotifly"`. Device names are not
  identity, and the section is disabled when no Connect device is active.
- [`SpotifyPlayer`](../../Spotifly/SpotifyPlayer.swift) owns one shared `AudioRenderer`, used
  across tracks and streaming-session reconnects. The renderer leaves
  `audioOutputDeviceUniqueID` at `nil`, so it follows the system's default output.
- [`AudioRenderer`](../../Spotifly/AudioRenderer.swift) maps a receiver's
  `enqueuedWithSuggestedFlush` to `.outputChanged`.
  [`AudioPipeline`](../../Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift) refills from the
  playhead. Its separate stall detector recovers system-default output changes.
- The existing refill requires a loaded pipeline with `isPlaying == true`, which includes
  a paused track. Its usual triggers do not cover a pause: the stall detector requires a
  running clock, and an enqueue can wait through the pause. An explicit app route switch
  must also work while paused, before a track loads, and after the last buffer. It cannot
  depend on another enqueue arriving.

Control Center selects the Mac's output. That can carry other applications' audio as well as
Spotifly. This feature must select only Spotifly's output. It must not temporarily change the
system output to establish a connection and then change it back.

### Known receiver and AirPlay scope

The user supplied a Control Center screenshot dated 2026-10-03, 19:05:57 local time. It lists
**Küche HomePod** as an available output, with **LG UltraFine Display-Audio** selected. The
user confirms that Küche HomePod is an AirPlay-enabled speaker. The screenshot establishes
system discovery of a known receiver; it does not prove renderer access, an active connection,
or the negotiated AirPlay version. "WohnzimmerStereo" is also listed, but its hardware and
capabilities have not been established and are not needed for the first test.

Apple documents [streaming from a Mac app to HomePod](https://support.apple.com/de-de/guide/mac-help/mchld7e543a0/27/mac/27).
Its [custom audio sample](https://developer.apple.com/documentation/avfaudio/playing-custom-audio-with-your-own-player)
describes AirPlay 2 with improved buffering and responsiveness on iOS, iPadOS and Mac Catalyst.
That sample credits its AirPlay 2 behavior to `AVAudioSession.longFormAudio`, which is
unavailable on native macOS. It is not evidence that native macOS HAL endpoint playback gets
the same sender-side enhanced buffering. Modern native AirPlay remains the user's preference;
legacy receivers, a hand-written RAOP sender, older macOS deployment targets and deprecated
renderer feeding are outside scope.
Multiroom controls remain a separate feature; preferring AirPlay 2 does not require building
those controls in the first version.

### API evidence, checked against Xcode 27.0 / macOS 27.0 SDK

| Public API | What it provides | Limit relevant here |
| --- | --- | --- |
| [`AVRoutePickerView.player`](https://developer.apple.com/documentation/avkit/avroutepickerview/player) | Native AirPlay selection for an `AVPlayer` on macOS | No renderer or receiver property; its header's sample-buffer support is for iOS/tvOS |
| [`audioOutputDeviceUniqueID`](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer/audiooutputdeviceuniqueid) | Selects this renderer's Core Audio output; `nil` means default | Does not discover or authenticate an AirPlay receiver; changing it can affect the render clock |
| [`AVRouteDetector`](https://developer.apple.com/documentation/avfoundation/avroutedetector) | Indicates whether additional playback routes exist | Does not return destinations or their Core Audio UIDs |
| [`AVRoutingPlaybackArbiter`](https://developer.apple.com/documentation/avrouting/avroutingplaybackarbiter) | Arbitrates playback routing on supported platforms | Explicitly unavailable on macOS in the 27 SDK |
| Core Audio transport managers and endpoint devices | Enumerate network endpoints and request a device composed from them | Declaration availability does not prove the AirPlay driver exposes these operations to our sandboxed app |

The Core Audio evidence is in the installed SDK's `CoreAudio.framework/Headers/`:

- `AudioHardware.h`: `kAudioHardwarePropertyTransportManagerList`,
  `kAudioTransportManagerCreateEndPointDevice`, `kAudioTransportManagerDestroyEndPointDevice`.
- `AudioHardwareBase.h`: transport-manager description names AirPlay and AVB;
  `kAudioTransportManagerPropertyEndPointList`, `kAudioTransportManagerPropertyTransportType`,
  `kAudioDeviceTransportTypeAirPlay`, and endpoint-composition keys.
- `kAudioEndPointDeviceIsPrivateKey = 1` describes a device private to its creating process,
  not persistent across process launches. Explicit cleanup is still required. This is a
  public API's process-private device, not use of a private framework. See Apple's references for
  [creation](https://developer.apple.com/documentation/coreaudio/kaudiotransportmanagercreateendpointdevice?language=objc)
  and the [private-device key](https://developer.apple.com/documentation/coreaudio/kaudioendpointdeviceisprivatekey).

Apple's general [AirPlay adoption guide](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app)
describes both AVPlayer and sample-buffer playback. Its `AVAudioSession.longFormAudio`
configuration is for iOS/tvOS/watchOS, and does not supply a native macOS renderer-to-picker
connection. Do not copy that configuration into this app.

### Checks performed in this investigation

On this Mac, macOS **27.0.1 (26A434)**, with Apple Swift **6.4**:

- A temporary API probe typechecked with Swift 6, complete strict concurrency,
  `-warnings-as-errors`, and deployment target macOS 27. It combined
  `sampleBufferReceiver(adding:)` with renderer-specific output selection and imported the
  public endpoint creation, destruction and composition symbols. No deprecated feed API
  was needed. This proves API availability, not connection or audible playback.
- A read-only Core Audio inventory, run outside the agent's execution sandbox, found five
  audio devices, none with AirPlay transport, **zero transport managers**, and two boxes,
  neither with AirPlay transport. The default output and alert output were the same display.
- Enabling `AVRouteDetector` for five seconds reported `multipleRoutesDetected == true`, but
  still exposed no AirPlay HAL device or transport manager. This flag does not identify the
  extra route or prove that an AirPlay endpoint can be activated through HAL. Detection was
  then disabled. No output, volume or playback was changed.
- Repeating that inventory after the user identified Küche HomePod produced the same result:
  extra routes detected, five HAL devices with no AirPlay transport, and no transport managers.
  Combined with the screenshot, this is evidence of a gap between system discovery and HAL
  exposure on this Mac, not evidence that the network has no AirPlay receiver.
- The repository already measured renderer-specific device changes returning
  `enqueuedWithSuggestedFlush` on macOS 27. See
  [`docs/cpu-benchmark.md`, "Feeding the renderer"](../../docs/cpu-benchmark.md#feeding-the-renderer).

These checks establish the routing boundary and a candidate public API path. They do not
establish that a disconnected HomePod, Apple TV or third-party receiver can be initiated with
it. No AirPlay playback or signed-app sandbox test was performed for this plan.

## Solution

### 1. Prove initiation and isolation before implementing the feature

First run only the inventory in a minimal disposable target against macOS 27, signed and
sandboxed like Spotifly with its existing entitlements. If it exposes no AirPlay transport
manager/endpoints, record that the current HAL approach failed and stop. Do not build the
connection/PCM prototype in that case. A retest needs a changed condition, such as a new OS
build, receiver software/network availability, or a documented native discovery activation
step that does not connect through Control Center or change either system default. Repeating
the same inventory with no changed condition is not another implementation phase.

Only if that inventory succeeds, extend the diagnostic for the steps below. Use
**Küche HomePod**, initially not selected as the Mac's
output. Its availability in Control Center is already established by the user's screenshot;
confirm it remains available when testing, without relying on a pre-existing connection for
the successful test. Record its HomePod software version. Do not change the system defaults
during the diagnostic's routing attempt.

1. Read `kAudioHardwarePropertyDevices` and the transport-manager list. Filter output devices
   and managers by the public AirPlay transport type. Read endpoint UIDs and channel
   capabilities from the reported endpoints. Do not infer UIDs from Bonjour service names.
2. Check for the endpoint-creation property on the AirPlay manager. If exposed, request one
   endpoint device with a unique app-owned UID, its actual endpoint/channel description, and
   `kAudioEndPointDeviceIsPrivateKey = 1`. Creation uses `AudioObjectGetPropertyData` with the
   composition dictionary as qualifier data; this read has a creation side effect. Read the
   resulting Core Audio device UID. Verify `kAudioEndPointDevicePropertyIsPrivate` returns
   the diagnostic process's PID. Destroy the device explicitly when done.
3. Give that UID to a renderer using the same receiver/synchronizer API as production, and
   feed test PCM. Read back both system defaults and play a separate sound through the
   unchanged system output. Confirm audibly that only the diagnostic stream reaches AirPlay.
4. Disconnect and reconnect from the diagnostic, without Control Center establishing the
   connection first. Check the same path inside the sandbox, protected/pairing destinations,
   receiver loss, and cleanup. On loss, record device-alive/listener timing, enqueue results,
   stalls, any fallback to the default output and any audible local leakage. Verify that
   route-aware recovery can hold playback before any such fallback becomes audible. If that
   cannot be ensured, this path fails the loss behavior below. Destroy only the endpoint
   device the diagnostic created.
5. Capture automatic-flush results when selecting while idle then loading, while paused,
   during an enqueue, and after the final buffer. Determine whether the first buffer with
   a suggested flush survives, and whether another explicit receiver flush changes the
   result. This determines the accounting/acknowledgment described in step 3; a blind second
   refill is not acceptable.
6. Record device output latency, safety offset, audible position against the synchronizer,
   the endpoint's current volume/control capabilities, and whether renderer gain still works.
   Do not force the receiver volume to maximum or change system volume. Sender gain must work
   at a usable receiver level; receiver loudness can remain controlled by HomePod's own controls.
7. Evaluate AirPlay 2 evidence using the rule below. A transport flag or audible PCM alone
   cannot pass this part of the gate. No legacy implementation can make the prototype pass.

### AirPlay 2 evidence and deferred decision

An AirPlay 2 claim needs either authoritative Apple documentation explicitly covering the
exact **native macOS** output path, or supported platform diagnostic output that identifies
the negotiated mode for that connection. Record the source/output and its meaning. The
currently cited general guide, iOS/Catalyst sample, HAL transport flag, HomePod capability and
audible playback do not provide that evidence. No suitable evidence for this HAL path has
been identified yet. Measure buffering separately; do not infer sender-side enhanced
buffering from the receiver model or ordinary HAL playback.

If the candidate can initiate an isolated native connection but only a generic/unversioned
AirPlay path can be established, defer product implementation for an explicit decision:
whether the current Apple stack with unverified protocol/buffering meets the user's
preference, or whether a separately planned, documented `AVPlayer` path is needed. The user
has not accepted the weaker result. This is a decision only if the candidate gets past the
currently failing discovery check; it does not block that cheap check or require a decision
now. Continue to exclude an AirPlay 1/RAOP compatibility sender.

**Pass condition:** the signed sandboxed process initiates a previously idle receiver,
receives audible PCM through the macOS 27 receiver, leaves both default outputs unchanged,
keeps unrelated audio local, satisfies the evidence/decision rule above, handles route loss
without local leakage, and releases its own connection. Save receiver model/software, OS
build, selectors, OSStatus results, transport evidence and audible observations here before
proceeding.

**Fail condition:** no endpoints/manager are exposed, creation is refused, pairing needs an
unsupported API, audio cannot render, connection requires a global output change, or the
approach depends on legacy AirPlay streaming. Stop the remaining steps and record the exact
limitation. A preconnected AirPlay HAL device alone does not pass the initiation requirement.
Do not ship a list of ordinary audio outputs under an AirPlay label as a substitute.

### 2. Add routing ownership after the gate passes

Add a small audio-output routing service, proposed at
`Spotifly/Store/Services/AudioOutputRoutingService.swift`. Keep UI state on `@MainActor` with
`@Observable`; keep HAL ownership behind a serialized boundary. Pass only `Sendable` route
descriptions and UIDs to playback. Do not export the non-Sendable renderer from its actor.

The service owns endpoint discovery, the app-created device and selection state: following
the system output, connecting, connected, or failed. Use public property listeners rather
than a discovery polling timer. Start discovery when Speakers is visible and release
discovery work when it closes; the selected connection outlives the view. A failed switch
keeps the previous usable route and shows a localized error.

Own the service in `LoggedInSession`, inject it through `environment(session:)`, and give it
explicit teardown. Closing the window must keep playback and the selected route alive.
After playback is stopped on logout, detach the renderer from an app-owned device before
destroying it. Streaming-session recovery must reuse the route; do not recreate a connection
for every track. Do not persist receiver UIDs or reconnect automatically across app launches
in the first version.

`LoggedInSessions.end()` is currently synchronous, and the shared renderer outlives it.
Await routing teardown in the common `AuthViewModel.logout` path after
`shutdownForLogout()` stops playback and before clearing `isSignedIn` ends the session.
Retain the service until cleanup has completed. Observe `PlayerModel` through `Observations`,
as `QueueService` does, to detect a handoff to an active remote device. Serialize release with
local playback stop; late callbacks cannot revive the released route. Do not subscribe to
the client's snapshot stream from a second UI service.

### 3. Switch the existing renderer through a playback transition

Expose a local output command through `SpotifyPlayer` and `LibrespotClient`, with the routing
service as its caller. Use `AudioPipeline.transition` to serialize it with loads, seeks,
pause/resume, stop and gapless continuation. Do not call the public `seek` command as a
routing shortcut: it can take over mirrored playback when nothing is loaded here.

For a loaded track, freeze playout, account for any reached gapless continuation, capture the
track-relative audible position and paused state, and retire the suspended decode task.
Then set the renderer's UID inside `AudioRenderer`, flush through its **Receiver**, and use
the existing seek/restart mechanics to refill from the saved position. Preserve paused
state, gain, track and queue. For an empty player, set the output for the next load without
starting playback. Test switching after decoding has finished as well as during an enqueue.

Changing the UID with no enqueue waiting can put the automatic-flush suggestion on the
**next** enqueue, including the first buffer of the next track after an idle selection.
Record a route-change generation and pending acknowledgment in `AudioRenderer`; retain it
across an idle selection. The renderer's enqueue path handles a suggestion attributable to
that change as a route acknowledgment instead of emitting generic `.outputChanged` and
calling `refill(after:)` again. After an idle selection, this belongs to the next load's
enqueue path even though the selection command has already returned. Use the diagnostic's
measurements to decide whether to account for
the enqueued buffer once and advance its timestamp, or flush/re-enqueue from the same saved
position. Keep `nextPresentationTime`, `flushes` and `decoded.frames` consistent with that
choice. The result must cause at most one pipeline seek/restart per explicit switch. Do not
blindly swallow an unrelated later suggestion: check generation, selected route and route
health, and prioritize a loss indication over acknowledgment. Exercise this after an idle
selection, pause, final enqueue and rapid successive selections.

Keep `sampleBufferReceiver(adding:)`, async enqueue backpressure, receiver flushes,
`EnqueueResult` handling and `allowedAudioSpatializationFormats`. Do not add the deprecated
`enqueueSampleBuffer`, readiness polling or feed callbacks. The existing stall fallback
still serves external changes while following the default output. Ensure an explicit switch
and its suggested-flush result cannot schedule two competing refills.

On a lost or unusable selected receiver, hold local playback paused at its current position
and show the route error. Observe `kAudioDevicePropertyDeviceIsAlive` and endpoint/device
removal, or an equivalent public signal validated by the diagnostic. Publish route health
to the serialized playback boundary as well as to UI state. Both `.outputChanged` recovery
and the stall/refill path must consult route health before restarting: keep the track held
when the selected route is lost, even if the renderer can now use the default output. A
listener is insufficient if testing shows audible fallback before the hold; then the approach
fails this requirement. Require an explicit choice to resume on the Mac. Release the private
device only after it is no longer the renderer's output. Late discovery/connection results
must not override a newer selection, logout, or a Connect handoff.

### 4. Make the Speakers section usable

Replace the unbound native picker with a destination list backed by the APIs validated in
step 1. Keep Spotify Connect devices in their existing section. AirPlay changes this Mac's
audio output, not its Connect identity or the remote Spotify player.

- Show available AirPlay destinations, the actual selected route, connection progress,
  errors, and an explicit "Use Mac output" action (`audioOutputDeviceUniqueID = nil`).
- Explain that the route carries Spotifly's audio. Update the existing hints in English,
  German and French. Keep the control visible when discovery finds no receiver.
- Compare nonempty `player.activeDeviceId` and `player.ownDeviceId`, not the device name.
  Allow selection before a track starts when `localPlayback == .ready` and no remote Connect
  device is active (`player.activeRemoteDeviceId`). Selection alone does not play or transfer
  a track.
- While a remote Connect device is active, explain that playback must return to this Mac
  through the existing Connect row before AirPlay can carry it. Preserve authorization and
  Premium notices. A handoff away stops local output and releases the AirPlay connection;
  coming back uses the Mac's output until another explicit AirPlay choice.
- First version: one destination at a time. Do not promise AirPlay 2 grouping, multiroom,
  remote receiver volume or metadata from HAL transport alone. Modern transport and buffering
  behavior must meet step 1's evidence/decision rule before choosing this path; grouping and
  other extra features can be verified separately. The existing volume slider remains stream
  gain, with HomePod's own controls for receiver loudness. Do not assume the Mac's volume keys
  control the selected app-only endpoint; verify their behavior and clarify it in the UI.

### Alternatives considered

| Approach | Assessment |
| --- | --- |
| Public HAL endpoint device + existing renderer | Recommended only after initiation, isolation and modern AirPlay behavior are established; preserves the macOS 27 playback path |
| Native picker + an empty/proxy `AVPlayer`, copying its UID to the renderer | Unverified: the API does not promise that selection publishes a transferable UID or that the player can relinquish the connection. Do not assume this is a supported bridge |
| Actually render Spotify audio through `AVPlayer` for AirPlay | Fits the native picker, but needs an AVPlayer-readable media source and changes playback, buffering, clocks and gapless ownership. A separate architecture proposal if HAL fails; this plan keeps the existing renderer |
| Change system defaults, private routing APIs, or implement RAOP/AirPlay ourselves | Does not meet the requested isolation or the scope of this plan |

### Implementation notes and handoff

The plan is a proposal, not authorization to implement product code. The next implementation
session starts with step 1's cheap signed inventory; the current unsandboxed result meets
its first fail condition. No user product decision is needed for that check. A generic native
connection with unverified AirPlay mode leaves the explicit decision described above open.
Keep measured findings and proposed
departures here. Once the design is accepted, preserve its isolation and renderer boundaries;
a necessary change to them requires an explicit design decision. Update this plan and move
it to `plans/done/` in the PR that completes the feature.

## Verification

### Required before product implementation

- [ ] The signed-app hardware gate passes from an idle receiver, with no Control Center
      connection prerequisite, and its evidence is recorded above.
- [ ] If the signed inventory repeats the current absence of AirPlay managers/endpoints,
      record failure and stop before implementing a connection or PCM prototype.
- [ ] Küche HomePod is the first receiver tested. Record its software version and the outcome
      of the AirPlay evidence rule, including any deferred decision. A generic HAL AirPlay
      flag is not sufficient version evidence; an unresolved decision still blocks product work.
- [ ] The implementation has no AirPlay 1/legacy RAOP compatibility fallback and retains
      the macOS 27 receiver API.
- [ ] A protected or unavailable receiver fails with a useful error through supported APIs.
- [ ] The gate runs with Spotifly's existing sandbox entitlements, or documents a specific
      supported entitlement requirement before changing them.
- [ ] Receiver loss cannot play through the default output; record the event order, fallback
      behavior and audible observations, not just device removal.
- [ ] Suggested-flush acknowledgment and buffer accounting are measured for idle selection,
      pause and final-buffer switches; there is no duplicate seek/restart.
- [ ] Device latency/safety offset, audible playhead offset and initial receiver loudness are
      recorded. Renderer stream gain works without forcing receiver/system volume changes.

### Acceptance after the gate and implementation

- [ ] Start a Spotify track here, choose the idle Küche HomePod in Speakers, and hear it there.
      Browser audio and a macOS alert remain on the original Mac output. Both HAL default
      output IDs remain unchanged throughout connection, playback and disconnection.
- [ ] Select before playing; select while paused, mid-track, at a gapless boundary and after
      the final enqueue. Preserve track position, pause state, queue, repeat and stream gain.
- [ ] Seek, Previous, Next, pause/resume, end of queue and gapless playback still work on
      AirPlay, with no hung enqueue, duplicate refill or unintended track restart.
- [ ] Test rapid selections, failed connection, receiver disappearance and sleep/wake.
      Failed attempts preserve the old usable route; a lost route does not play aloud locally.
- [ ] Closing/reopening the window and a Spotify reconnect keep the route; logout and
      transfer to another Connect device release it safely. No stale callback restores it.
- [ ] A remote device named "Spotifly" cannot enable local routing; authorization and Premium
      failures remain accurate. Returning to this Mac does not silently reconnect AirPlay.
- [ ] "Use Mac output" restores following the default. Changes from Control Center, wired
      headphones and AirPods still work, including the existing Spatial Audio policy.
- [ ] Add focused tests for route-state ordering/cleanup, local-device identity, and playback
      transitions while paused or decoding is finished. Use hardware tests for discovery and
      audible isolation; a mocked destination cannot prove AirPlay initiation.
- [ ] Build and run relevant tests on macOS 27 with Swift 6 strict concurrency; use
      `swiftformat --swiftversion 6.4 .` for product changes. Update `DEVELOPMENT.md` and the
      changelog to describe only the behavior measured and delivered.

### Verification of this plan PR

API typecheck and read-only device/route detection were performed as described above.
Product code was not changed. Audio isolation, AirPlay initiation and connection cleanup
remain untested. Markdown structure, local repository links and `git diff --check` passed.
No app build or product test suite was run for these documentation-only changes.

### Independent review

Claude Code reviewed commit `9c47484` against the source, installed macOS 27 SDK and Apple
documentation on 2026-10-03. It confirmed the API/platform claims and identified four plan
gaps: current discovery evidence already meeting the fail condition, undefined AirPlay 2
evidence, duplicate refill risk after a UID change, and route-loss recovery allowing fallback.
The plan now addresses each and includes the minor corrections on privacy lifetime, paused
refill triggers, latency, volume and teardown. Claude's read-only recheck of the revised
working tree on 2026-10-03 marked all four findings resolved, with no important findings
remaining, and judged it ready as a conditional planning document. Its optional wording
fixes on the evidence checklist, acknowledgment after idle selection and this review note
are included. Claude did not re-run the typecheck, inventories or document checks; the
document checks were run separately by the author. Hardware feasibility remains unproven.
