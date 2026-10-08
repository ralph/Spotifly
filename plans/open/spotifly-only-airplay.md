# AirPlay from Speakers without sending the Mac's other audio

Status: **Open**, 2026-10-08; draft proposal. Native `AVPlayer` AirPlay initiation and
audible isolation passed with Küche HomePod after a receiver restart. The HAL candidate
failed discovery, and the production renderer did not inherit the player's route in the
two-tone test. Complete Float32 WAV and CAF fixtures passed HomePod playback/isolation
with fresh baselines and qualified seek checks. A disposable build using the unchanged
Spotify decoder and the app's cached real-track input also passed HomePod playback, concurrent
Safari/alert isolation, pause/resume and an active seek for one song. An `AVPlayer` production
backend remains a separate design decision. The passive observation build passed local
silent checks and two bounded listening cases: fast intentional return to Mac, and silence
after HomePod power loss with no heard local fallback. The sampled player clock kept advancing
through the loss case; this supplies no production loss-protection guarantee.
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

**Native AAC app-only AirPlay passed in one earlier hardware run on the tested setup.**
A separately signed sandboxed `AVRoutePickerView` + real `AVPlayer` probe played its AAC tone on Küche HomePod
while the user confirmed other sounds stayed local. Both system output defaults remained
on the Mac's speakers. The earlier connection failure disappeared after restarting HomePod,
without changing the probe code.

**This does not provide a bridge to the current renderer.** The HAL inventory gate failed:
no AirPlay device or transport manager was exposed. All sampled states, including successful
native playback, exposed no AirPlay device/manager and `AVPlayer.audioOutputDeviceUniqueID`
was `nil`, supplying no UID to give the sample-buffer renderer. Stop the HAL connection
and sample-buffer PCM experiment in the tested app configuration on macOS 27.0.1.
The remaining HAL design is conditional reference material. A Spotify-compatible `AVPlayer` media-source and playback architecture
would need a separate investigation and design decision; the successful AAC fixture does
not justify replacing the macOS 27 renderer yet.

**Implicit route inheritance also failed in the two-tone test.** With the unchanged
production renderer in the same process, tone A reached HomePod through `AVPlayer`, but
renderer tone B stayed on the Mac with A playing and paused. B accepted buffers and its
clock advanced without recorded errors/stalls. The startup baseline was stale after a
display disappeared, so the full-run unchanged-default criterion did not pass; the actual
test snapshots all used the Mac for audio and alerts. This rejects the tested inheritance
hypothesis, not every conceivable renderer integration. The next useful candidate is an
actual `AVPlayer` media source, keeping the current renderer for local output.

**Complete Float32 WAV and CAF playback/isolation passed on the tested HomePod.** The
user heard each generated fixture there while Safari YouTube and a system alert preview
stayed on the Mac concurrently. Both runs had fresh baselines; all 45 sampled audio/alert
output checks remained on the Mac, with no reported errors. Audible pause/resume passed
for both; WAV seeks were paused then resumed, while CAF continued after a seek during
playback. The prior 22 checks and silent runtime passed too. This supports the complete-file
media-source candidate; the subsequent real-track test below checks actual decoder delivery.

**One cached real Spotify track also passed app-only HomePod playback.** The disposable
Spotifly copy used the unchanged production decoder to prepare a complete Float32 CAF, then
played the song through the native picker/player. The user confirmed a Mac baseline, HomePod-only
music, concurrent Safari/alert audio local, audible pause/resume and a recognizable backward
seek while playback continued. All 17 pasted captures retained Mac output defaults. For the
210.56-second track, cached-input preparation including complete verification took 0.94 seconds
and temporary storage was 74.3 MB. Earlier download/decryption is excluded. This establishes
one complete-file Spotify media-source candidate; production handoff, queue/gapless, loss
protection and negotiated AirPlay mode remain untested. The later bounded power-loss
observation found silence without heard Mac fallback while the player clock advanced.

Target **modern AirPlay 2 through Apple's current macOS 27 stack**, with "Küche HomePod" as
the first test receiver. Prefer the newest behavior the native stack and receiver support.
Do not implement an AirPlay 1/legacy RAOP sender or support older OS renderer APIs. Protocol
negotiation through the native picker/player is owned by macOS and was not identified in
this test. A generic HAL AirPlay output is not evidence of the desired modern transport.

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
establish receiver initiation through HAL. The signed-app inventory below confirms that
candidate's initial failure. The subsequent native picker/player test is recorded separately.

### Signed sandboxed inventory result

The disposable **Spotifly AirPlay Probe** ran on 2026-10-03, with its final report export
verified on 2026-10-04. It was built with Swift 6 complete strict concurrency and
`-warnings-as-errors`, targets macOS 27 and is Developer ID signed on Spotifly's team
`89S4HZY343`, with bundle ID `rvdh.SpotiflyAirPlayProbe`. Its reported home is inside
`Library/Containers/rvdh.SpotiflyAirPlayProbe/Data`, confirming the app container is active.
`codesign --verify --strict` passed. Seven result-classification checks passed, including
distinguishing failed HAL reads from confirmed absence and rejecting changed defaults.

The probe retains Spotifly's sandbox, network client/server and selected-file read-only
entitlements. Its unused shared keychain group is omitted: macOS refused that entitlement
for the new bundle without a provisioning profile (AMFI -413). It never accesses Spotify
credentials, and that omission does not expand audio or network permissions.

On macOS **27.0.1 (26A434)**, before and after five seconds of `AVRouteDetector` discovery:

- `multipleRoutesDetected` was **true**.
- Five HAL devices were exposed, with USB, built-in and virtual transports; none used
  `kAudioDeviceTransportTypeAirPlay`.
- `kAudioHardwarePropertyTransportManagerList` (`tmg#`) was supported and returned **zero
  bytes / zero managers with OSStatus 0**. This was a successful empty read, not a read error.
- Two boxes were exposed, neither with AirPlay transport.
- Default audio and alert outputs both remained **96**, the two-channel LG display device.
  All reads used the public property APIs; no endpoint was created, output or volume set,
  or audio played.

**Result: the first HAL gate failed.** The signed app repeats the unsandboxed discovery
limitation, so no HAL connection or sample-buffer PCM prototype was built. The user then
requested the separate native picker/player test below. The local diagnostic source and
app are kept outside the product repository in the workspace's `airplay-probe/` folder,
with JSON and text reports available from its window; no diagnostic is shipped in Spotifly
or included as product implementation in this PR.

### Native picker/player hardware result

The follow-up probe assigns a real `AVPlayer` to `AVRoutePickerView.player`, loads a bundled
120-second stereo AAC tone and starts paused. The user selects the receiver in the native
picker and explicitly starts playback. It uses the same signed sandboxed target and permissions
described above; it does not change either system output default. Twelve diagnostic checks
passed: seven inventory classifications and five audio/alert-default comparisons. These
checks validate report logic; the audible result comes from the user's hardware test.

On **2026-10-04**, macOS **27.0.1 (26A434)**, run
`7F3E3736-C5DE-40FB-89A2-FB1CD0E1E48B`:

- The user reports that **restarting Küche HomePod resolved the connection failure**, then
  confirms **Tone on HomePod: Yes** and **Other sounds stayed local: Yes** in the exported
  report. No probe code changed between the failed and successful attempts.
- Default audio and alert outputs both remained **83**, the MacBook's built-in speakers,
  at preparation, picker dismissal, two seconds later, Play and a capture during playback
  (07:42:24–07:44:00 Europe/Berlin). These are sampled observations, with audible isolation
  confirmed by the user, rather than a claim of continuous HAL monitoring.
- All five snapshots exposed four HAL devices, none using AirPlay transport, and **zero
  transport managers**, including the capture during audible playback. Restarting HomePod
  therefore did not expose the endpoint needed by the stopped HAL approach.
- The player reached `ready` / `playing`, but its output-device UID was **nil** in all five
  snapshots. In this run, that property's probe label "default output" did not predict the
  observed picker-selected HomePod audio route. No explicit HAL UID was observed through it.
- `isExternalPlaybackActive` remained false. The installed SDK describes this flag as
  external **video** playback; it cannot reject the positive audio observation.
- Platform logs show a 30-second control-connection timeout (`-6722 / kTimeoutErr`) for
  the failed attempt at 07:37, then successful native activation in 498 ms at 07:42. This
  is connection-activation timing, not media latency. No matching sandbox/TCC denial was
  found in the failure window. Playback worked after the receiver restart; the underlying
  reason for the earlier timeout is not established.

**Result: native `AVPlayer` initiation and app-only audible isolation passed in one run
for the AAC fixture on this HomePod after a restart.** This is positive evidence for using
the native picker with an actual player; it is not evidence of a supported bridge to the
sample-buffer renderer. Repeatability and whether future attempts need a receiver restart
remain unverified. Spotify media delivery, gapless behavior, route loss and cleanup remain
untested. HomePod software version, negotiated AirPlay version and sender buffering mode
were not recorded.

### Follow-up HAL inventory after the successful native test

The user supplied another inventory run started on **2026-10-04 at 07:47:38 Europe/Berlin**
(05:47:38 UTC), after the HomePod restart and successful native-player test. Before and
after five seconds of discovery, both output defaults were **83**, four non-AirPlay HAL
devices were exposed and the transport-manager read again returned **OSStatus 0, zero
bytes, zero managers**. `multipleRoutesDetected` was true. No endpoint creation or playback
was attempted in this inventory run. This independently repeats the HAL limitation after
the receiver recovered; it does not contradict the native player's successful routing.

### Route-inheritance experiment result

The user authorized a separate two-tone experiment on 2026-10-04. The signed sandboxed
**Spotifly Renderer Route Experiment** compiles the unchanged production `AudioRenderer.swift`
with its macOS 27 async Receiver; the compiled source's SHA-256 is recorded in each report.
Tone A uses the proven native picker/player path. Tone B is distinct 220 Hz Float32 stereo
PCM through the production renderer, with no explicit UID or system-output change.

First confirm B plays locally, then choose HomePod for A, play both and pause A while
keeping its item loaded. Record where B is heard, unrelated audio, both default outputs,
A's actual playback state and B's enqueue/clock progress. B on HomePod with unrelated
audio local would support implicit route inheritance on this configuration, requiring
further lifecycle tests and a supported integration design. B on the Mac rejects that
hypothesis; silence or enqueue errors are inconclusive. This does not revive the stopped
HAL endpoint-creation candidate or prove a public picker-to-renderer bridge.

The disposable app remains outside the product repository in `renderer-route-experiment/`.
Its 22 diagnostic checks and strict Swift 6 build/signature verification passed. A silent
signed-app launch confirmed an active sandbox, ready/paused AVPlayer, no B enqueue and an
exact production renderer fingerprint. The user then supplied run
`3D1CBCB4-2F66-400E-ADE0-06B62B9B9A39` on macOS **27.0.1 (26A434)**:

- **B baseline: Mac; A on HomePod: Yes; B with A playing: Mac; B with A paused: Mac;
  Other sounds stayed local: Yes.** The recorded renderer SHA-256 matches the unchanged
  production source compiled into the app.
- A was `playing` at rate 1 when B started. After pausing A, its item remained `ready`,
  playback was `paused` at rate 0, and B continued accepting buffers with an advancing
  clock. Two seconds after the pause B had played 463,132 frames and accepted 25 buffers.
  No captured renderer issue or stall was recorded. This was audible local B playback,
  not a silent renderer or failed feed being mistaken for a routing result.
- All eight captured stages from the local B baseline through the final B stop used
  **84/84**, the MacBook speakers, for default audio/alerts. HAL exposed three non-AirPlay
  devices, zero managers and no explicit player output UID at these stages.
- The report correctly says **defaults across sampled captures: changed**. Preparation
  was at 14:01 Europe/Berlin with defaults **84/96** and LG display devices present. The
  first B start at 20:05:28 already showed **84/84**, with the display devices absent;
  Play A was later at 20:06:00. The alert-default change occurred between those samples
  before Play A. Its exact time/cause and relationship to picker selection were not
  captured. Do not attribute it to this app or claim full-run output stability. Future
  isolation tests should start a fresh run after the intended Mac outputs are available.

**Result: no implicit AVPlayer-to-renderer route inheritance was observed in either tested
playback state.** The stale-baseline change prevents a whole-run isolation pass, but does
not erase the user's negative B observation under the consistent active-test outputs.
This does not prove that every possible renderer bridge is impossible. No Spotify/product
code changed; an AVPlayer-readable media source is the next alternative to investigate.

### Complete PCM asset fixture (hardware results)

On **2026-10-07**, the user authorized the next disposable experiment. The app and sources
are kept outside the product repository in the workspace's `pcm-asset-airplay-probe/`
folder, with build and listening instructions in its README. It uses a distinct bundle
from the earlier probes, preserving their reports. No product source changed.

The AAC fixture already established native initiation/isolation once. This probe asks the
narrower question of whether the renderer's **Float32 PCM format**, packaged as a complete
file, is also usable by that player/picker path. It cheaply checks a container/format
boundary; the hardware pass only modestly reduces integration risk. The actual pipeline
downloads a complete encrypted track before decoding it, then emits PCM in paced chunks.
The later actual-decoder experiment below establishes a complete CAF for one cached track;
a production media source still needs suitable startup, clocks, queue behavior and output
handoff. These Float32 results do not validate or exclude Int16 PCM, ALAC or other sample formats.

- The input is the same generated low 220 Hz pulse used for B in the inheritance test:
  **44.1 kHz, stereo interleaved Float32**, matching the decoder/renderer PCM format.
  This app does not compile the Spotify decoder or the current production renderer.
- `AVAudioFile` writes complete **WAV** and **CAF** files in half-second chunks, then
  closes their headers. Actual container signatures, PCM format/frame count and every
  sample are verified by complete readback. There is no AAC intermediary or PCM compression.
  Each 120-second asset has **5,292,000 frames** and is **42,340,096 bytes** on this runtime.
  Both `AVURLAsset` playability/duration checks and `AVPlayer` item readiness passed.
- A native `AVRoutePickerView` is attached to that real `AVPlayer`. The app starts paused
  and requires a user Play action. Controls include per-stream gain, pause/resume and
  seeking to 30 seconds. File format changes pause playback and archive the previous report.
- **Start new run / capture baseline** records the baseline immediately before testing;
  startup does not implicitly establish it. Changing format clears the baseline and
  listening observations and disables Play until another explicit run starts. All sampled
  comparisons are retained so a later unchanged read cannot hide an earlier changed or
  unreadable audio/alert default. Picker dismissal is recorded without asserting selection.
- Reports include asset metadata, generation/readback/check timing, player state/position,
  actions, HAL inventory/default IDs and manual observations. An item-load failure is saved
  and can be copied; another format remains selectable. Normal shutdown unloads the player
  and removes generated temporary assets while keeping reports in the app's sandbox.
- The final Swift 6 strict-concurrency/warnings-as-errors build, Developer ID signature,
  **22 checks** and signed sandboxed silent runtime passed. Runtime checks exercised
  WAV → CAF → WAV, seeded observation reset, four distinct fresh run IDs, a deliberately
  withheld CAF file with persisted failure and recovery to WAV, and asset cleanup. Every
  logged state had zero rate/position and paused control; stderr was empty. No audio was
  played and no remote route was selected. Source review found two recovery/cleanup gaps;
  both were fixed and rechecked. Initial player-load failure was source-reviewed, not
  separately simulated; format-load recovery was exercised in the signed runtime.
  The same final build was launched for the subsequent listening runs; both supplied
  report run IDs match that launched probe's local JSON log. No probe code changed during
  listening. A source/binary fingerprint was not included in the user-facing PCM reports.

Preparation of both synthetic files, full readback and asset checks took about **2.13 s**
in that diagnostic run, before the first player item became ready. It excludes Spotify
download/decode and is not a product startup estimate. The two files use about 85 MB together;
production delivery/storage/lifecycle still need design.

**Hardware listening passed separately for WAV and CAF on 2026-10-07**, using macOS
**27.0.1 (26A434)** and Küche HomePod. The user followed one step at a time, recorded each
format in a separate run, and explicitly confirmed the concurrent sounds in this chat.
The raw reports remain local; sanitized detailed/combined results are in the workspace
probe's `results/` folder.

| Observation | WAV | CAF |
| --- | --- | --- |
| Fresh baseline, Europe/Berlin | 19:59:33 | 20:10:52 |
| First local Play | 19:59:39 | 20:11:03 |
| Pulse before/after native picker selection | Mac → HomePod | Mac → HomePod only |
| Concurrent Safari YouTube audio | Mac | Mac |
| Concurrent system alert preview | Mac | Mac |
| Audible pause/resume | Passed | Passed |
| Seek to 30 seconds | While paused, then resumed | While playing, continued automatically |
| Sampled audio/alert defaults | Mac speakers, 83/83 throughout | Mac speakers, 83/83 throughout |
| Captures | 28 | 17 |
| Reported error | None | None |

The baselines preceded local Play by six seconds for WAV and eleven for CAF. Every
capture exposed four non-AirPlay HAL devices, zero managers and nil player output UID;
successful remote audio still supplied no transferable route for the production renderer.
Both local assets retained the verified format/sample counts above. Preparation was
**2.18 s** in the listening app session, with the same timing limitations as the smoke run.
This is one receiver/OS configuration and two sequential container runs, not broad
compatibility or independent-session reliability evidence. Receiver software and negotiated
AirPlay mode remain unknown. The old inheritance report's stale baseline is not reused.

Seek evidence is qualified: the WAV report records two seeks **to** a player-reported
30 seconds while paused, then Play and advancing time; the user heard the pulse afterward.
CAF's seek at **20:15:23** completed while playing, rate 1.0, player-reported position 30.0.
Two seconds later it was still playing at 31.832567965 seconds, with no later Play request;
the user confirmed automatic continuation
on HomePod. Identical repeating pulses cannot establish the exact content position heard
at the receiver, even when the application position/state and continued audio are correct.
The different seek procedures are not evidence of a format difference: active-playback
seeking was observed once in the CAF run and was not tested in WAV. Neither format is
preferred or selected by this result. Concurrent Safari and alert confirmations were
collected independently in **each** run, not reused from WAV for CAF.

Local file sample equality establishes a lossless asset, not lossless AirPlay transport.
These listening tests establish this generated complete-file candidate on the tested
setup. They do not prove actual Spotify decoding, incremental/live PCM delivery,
queue/gapless clocks, reliable reconnection, safe route loss, negotiated AirPlay version or
the accepted production backend. The hardware result is based on concurrent user
listening and sampled defaults.

## Solution

### 1. Prove initiation and isolation before implementing the feature

**Current HAL outcome: inventory failed at the sampled stages, including successful native
`AVPlayer` playback; do not proceed to HAL connection or sample-buffer PCM experiments in
this signed sandboxed app configuration.** The unsandboxed inventory also failed.
The separate native-player fixture passed initiation/isolation above. Retain the following
HAL steps for a future changed condition; they are not an implementation plan for `AVPlayer`.

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
| Public HAL endpoint device + existing renderer | First signed discovery gate failed on this Mac. Conditional only on a changed platform condition and a complete hardware pass; preserves the macOS 27 playback path |
| Native picker + an empty/proxy `AVPlayer`, copying its UID to the renderer | The real-player test supplied no UID or AirPlay HAL device even during successful audio. The API does not promise a transferable UID or connection ownership transfer; no supported bridge was demonstrated |
| Implicit route inheritance from a real `AVPlayer` in the same process | Negative in the two-tone test: production-renderer B stayed on the Mac while A played on HomePod and while A was paused; B's feed/clock remained active |
| Actually render Spotify audio through `AVPlayer` for AirPlay | Native AAC and generated PCM fixtures passed, followed by one cached actual Spotify track decoded to complete CAF with HomePod-only playback. A production design for startup, handoff, buffering, clocks, queue/gapless and route-loss remains required; this plan keeps the existing renderer |
| Change system defaults, private routing APIs, or implement RAOP/AirPlay ourselves | Does not meet the requested isolation or the scope of this plan |

### Actual Spotify decoder experiment (hardware results)

The authorized spike is a disposable copy of Spotifly, based on commit `17dc2ff`,
with an **AirPlay Experiment → Open Spotify audio experiment** window. The user first
plays a song locally through this copy's ordinary Spotify pipeline. A gated hook pauses
that pipeline inside its existing transition serialization and snapshots the loaded track's
already downloaded/decrypted Ogg bytes. The cache is populated only after a successful
whole-file `URLSession.download` with HTTP 200, decryption and removal of Spotify's leading
Ogg pages; it is not progressively filled. The hook uses exactly the resulting `current.ogg`
stream handed to normal playback, from cached byte zero through its end. A separate instance of the **unchanged production
`VorbisDecoder`** writes the complete decoded track to a temporary Float32 stereo CAF.
The existing macOS 27 `AudioRenderer` is also unchanged and stays paused. No Spotify key,
credential or network URL is exported to the experiment report.

The probe requires a finite 44.1 kHz stereo Vorbis track. It verifies the advertised decoded
frame count, actual CAF header/PCM format, every readback sample byte against a second
instance of the same decoder, AVURLAsset playability/frame-derived duration and AVPlayer readiness.
Readback honors short reads before EOF. The native picker is bound to this actual AVPlayer;
route selection and Play are manual, with a fresh local baseline captured explicitly.
CAF is chosen to bound this experiment to one container, not because the earlier tests
established an advantage over WAV.

Its report records decrypted input size, decoded frames/rate/channels, frame-derived and
Spotify-metadata duration, temporary CAF bytes, decode/write and complete-readback time,
and total preparation **including the verification pass** through item readiness. The second
instance of the same decoder checks CAF write/read integrity, not independent codec
correctness. The report labels that verification time separately and records the cached
input byte range and decoded-minus-metadata duration difference. **Download and decryption happened earlier
in ordinary playback and are excluded from preparation time.** Local sample-byte equality
preserves decoded PCM; it says nothing about the earlier lossy encoding or AirPlay wire format.
Source fingerprints confirm the compiled decoder and renderer match the product checkout.

This copy retains the ordinary app identity, developer team, sandbox/network/selected-file/
keychain entitlements and matching signing profile, so it reuses the existing account.
Quit ordinary Spotifly before launching it; do not obtain a second OAuth grant for the probe.
The user approved macOS's startup permission. Its silent mode skips authorization and
obsolete-grant cleanup entirely and uses only the bundled short Vorbis fixture. The copied
unit-test host uses different, ad-hoc signing; it does not establish production-entitlement
behavior. The signed smoke validates the listening app's own sandboxed startup.

**This is a cached complete-track experiment, not a backend handoff.** Its separate player
starts at zero; the ordinary playback bar and Spotify Connect state remain paused and do
not represent experiment playback. Experimental Play pauses the ordinary pipeline first.
If ordinary rendering later resumes, monitoring pauses the experiment, but that is not a
proof that every possible overlap race is prevented. Temporary PCM is removed on replacement,
window close and normal quit; unexpected termination may leave a temporary folder. Technical
reports retain metadata, not audio or account secrets. No queue/gapless, return-to-renderer,
route-loss or AirPlay-version capability is inferred. The source snapshot/build recipe stays
outside this documentation-only PR.

On **2026-10-07**, the user completed the guided real-song test on macOS 27.0.1
(build 26A434). The pasted report and the experimental app's own launch log correlate
by run ID and matching decoder/renderer source fingerprints. Its input was the exact cached
post-page-removal Vorbis stream from ordinary Spotify playback, not the bundled test fixture.
The signed listening build retained the ordinary app identity/entitlements. No code change
occurred during this listening run. The copied unit-test host remains a separate configuration.

| Measurement for this one cached track | Result |
| --- | --- |
| Cached Vorbis input | 7,300,765 bytes; byte range `0..<7300765` |
| Complete decoded PCM | 9,285,794 frames; 44.1 kHz, stereo, 32-bit Float32 |
| Frame-derived and playable asset duration | 210.562222 seconds |
| Spotify metadata duration | 210.562 seconds; decoded-minus-metadata delta approximately 0.22 ms |
| Temporary CAF | 74,290,448 bytes (74.3 MB decimal); same-decoder PCM bytes preserved |
| Decode/write | 0.4214 seconds |
| Complete verification readback | 0.3922 seconds, using another instance of the same decoder |
| Cached-input preparation through AVPlayer readiness | 0.9385 seconds, including verification; earlier network/decryption excluded |

- The user heard ordinary Spotifly playback and the experiment's fresh baseline on the Mac.
  After selecting only Küche HomePod in the experiment's native picker, the user heard the
  actual song on **HomePod only**.
- Safari YouTube audio and a system alert preview each stayed on the **Mac while the song
  continued on HomePod**. This is the user's concurrent listening observation. The later
  manual routing capture was taken after the user had paused; it does not itself prove
  concurrent audibility.
- Audible Pause stopped the HomePod song before its end, at player position approximately
  97.15 seconds; Play resumed it on HomePod only. An active seek completed at 21:45:19
  Europe/Berlin, with player rate 1 and position 30 seconds; its delayed capture showed
  31.577 seconds, still playing. The user recognized the earlier part of the song and
  confirmed continuation without pressing Play again. Exact receiver position/latency was
  not measured. No additional final manual capture appears in the pasted snapshot.
- All **17 pasted captures** from baseline at 21:27:25 through the delayed seek capture
  at 21:45:21 Europe/Berlin retained Mac defaults for audio and alerts. Local Play followed
  the fresh baseline by 44 seconds. These are samples, not continuous monitoring. Long gaps
  included explicit user pauses during the guided conversation. No reported error, AirPlay
  HAL device/manager or transferable player output UID appeared.

**Result: the complete cached-track CAF candidate passed real Spotify-song playback/isolation
and the tested controls on this setup.** The duration difference satisfies the predeclared
exploratory 1-second criterion. Neither complete asset conversion nor this listening test
proves uninterrupted start-to-end playback, general track-format support, uncached startup
cost, production backend transitions, queue/gapless behavior, receiver loss or a negotiated
AirPlay version. This is one song on one receiver. No receiver restart was requested as part
of this guided run; receiver uptime and repeated-session reliability were not established.
Here, app-only isolation describes this AVPlayer's Spotify audio versus other apps and system
alerts. Arbitrary other audio sources in the same app were not tested; the ordinary renderer
was paused. Listener-reported HomePod-only output does not measure brief local bleed during
selection/startup. The controls result covers audible pause/resume and one recognizable
backward seek while playing, not receiver seek accuracy, latency or every seek state.
Remote volume interactions, picker route-state accuracy, Now Playing/remote commands and
background/sleep/relaunch behavior were not checked by this listening run.

### Receiver loss and deselection observation (bounded hardware results)

The user-authorized disposable spike extends the actual-track experiment with two
separate **60-second passive observation windows**: intentionally choosing the Mac in the
native picker, and physically disconnecting HomePod power while the song is playing. The
user requested overnight work to remain silent on 2026-10-07, then explicitly resumed
listening on 2026-10-08. No overnight hardware playback occurred. The earlier successful
real-song result is unchanged; the new observations below do not re-test its unrelated-audio
or active-seek claims. No scheduled or automatic playback is authorized.

This build preserves the prior listening app as a separate local artifact and retains the
same app identity/signing configuration. It adds no loss protection or automatic routing.
Starting/stopping/expiring an observation leaves playback unchanged. Ordinary renderer
resume monitoring remains separately labeled, so its protective pause cannot be mistaken
for an automatic AVPlayer response to loss.

- Record player state/rate/position, waiting reason/error and audio/alert default IDs at
  nominal half-second intervals, plus work/scheduling. HAL/player reads are not atomic.
  Samples and ordered item-notification callbacks use monotonic elapsed time. Callback
  timestamps describe delivery, not the exact physical disconnect or audible transition.
  Background scheduling can miss short transitions, and receiver buffering can outlast
  recording. The observation window does not bound later fallback.
- Listen separately for intentional local return and unexpected local fallback after loss;
  record Mac/HomePod/Both/Silence and temporary changes. A manual change marker is only
  a listener action marker. Begin near the song's start with sufficient remaining duration;
  an end-of-item notification distinguishes natural completion from loss.
- Item stalled, failed-to-end, time-jump, end-of-item and new-error-log notifications are
  scoped to the experiment's item and preparation generation. These generic public events
  are not assumed to be guaranteed receiver-loss or route-deselection signals. Missing
  events or silence during one finite window cannot establish fallback prevention.
  Record receiver firmware, trial order/count and the particular loss mechanism. This
  first power-loss case supplies no network-loss, takeover, sleep/wake or other-receiver
  evidence. Picker presentation callbacks describe UI presentation, not route success.
- Preserve completed/interrupted traces in the technical report and reject stale item,
  run/watch, monitor and preparation callbacks after replacement/close/reopening. Reports
  and source/build artifacts stay local. Default comparisons include the watch samples.

After listening, use the observed event order and audible outcome to design receiver-loss
handling and bidirectional output handoff. No production protection is accepted until
the route behavior or a preventive mechanism can prevent unintended local audio; a reactive
pause can arrive after fallback has begun. Local silent lifecycle checks do not supply
that guarantee.

On **2026-10-08**, one restarted fresh run completed both cases in this order on
macOS **27.0.1 (26A434)**. A screenshot supplied after the tests reports HomePod software
**27.0 (24J361)** and model code **MY5H2D/A**. Both Mac audio/alert defaults were **83**
at baseline. The same complete 210.56-second Spotify CAF was used; the decoder/current
renderer fingerprints match. The earlier mistaken attempt is excluded from these results.

| Case | Recording | Listener result | Sampled player result |
| --- | --- | --- | --- |
| Intentional native-picker Mac selection | 60.17 s; 104 entries, including 97 output polls | Music returned to Mac; user described device switches as fast | Every sample ready/playing, rate 1; position 17.55 → 76.93 s; one delivered time-jump notification |
| Physical HomePod power removal | 60.12 s; 86 entries, including 84 output polls | After unplugging, music stayed silent and never returned to Mac during the user's observation | Every sample ready/playing, rate 1; position 36.40 → 95.87 s; no recorded item notifications, waiting reason or error |

All **181 watch output polls** and **23 ordinary full captures** retained both Mac default
IDs against the fresh baseline. The defaults stayed local at those recorded times;
the listener supplies audible-destination evidence. Both windows ended
by timer expiry. The user manually paused afterward and captured **After choosing Mac: Mac**
and **After HomePod loss: Silence**. Neither window reached the asset's natural end.

The loss marker was recorded **10.68 s after recording began**, leaving approximately
**49.45 s after the marker**, not 60 seconds after disconnection. The instruction placed
the marker before unplugging; exact physical-loss time is unknown. The selection case has
three later manual markers and one time-jump callback around picker presentation. These
are insufficient to measure audible switching latency or make that callback a route signal.
"Fast" is the user's qualitative report, with no quantified gap/overlap result. Polling may
miss brief transitions. Reconnecting power afterward is not a controlled reconnect/resume
test. Receiver network loss, takeover, sleep/wake, repeated trials and longer intervals
remain untested. The raw final report and sanitized listening record stay local.

**Design consequence:** player state/clock and generic item events did not identify this
power-loss case. No automatic pause/hold was observed in the samples, and the experiment
implemented none. Do not build loss detection solely from those fields or infer guaranteed
no-fallback behavior from this single silent outcome. The AVPlayer candidate still needs
supported audio-route observability or a preventive routing contract, explicit local-return
intent, reconnect policy and hardware validation before accepting production isolation.

### Implementation notes and handoff

The user authorized the disposable probes. The signed HAL inventory failed; the native
picker/player fixture passed initiation and isolation, without supplying a renderer UID.
The subsequent production-renderer experiment observed no implicit route inheritance.
Product implementation remains conditional and stopped. A future session must establish
a changed HAL discovery condition or investigate a separately planned Spotify-compatible
`AVPlayer` media-source architecture before proposing product changes. That investigation
must cover seek/pause/Next, buffering and gapless clocks, route-loss isolation, cleanup,
and modern AirPlay evidence. A complete CAF from one cached Spotify track now establishes
a readable delivery candidate. The production design must verify that `AVPlayer` can meet
each playback, stream-gain and gapless requirement and quantify uncached end-to-end startup.
Repeat initiation across multiple sessions, including without a HomePod restart. Give this candidate its own
route-loss gate: loss must hold playback before local fallback becomes audible, with
supported observability and recorded event order; reject the path if that cannot be ensured.
The bounded loss/deselection pilot above is now complete for one power-loss and one
intentional-selection case. It found no heard fallback, but also no sampled pause or
notification detecting power loss. Supported audio-route observability and a preventive
routing contract remain factual investigation; the pilot does not accept a protection design.
The renderer UID/suggested-flush rules above apply to the HAL candidate, not the player.
State whether AirPlay needs a separate output backend and what happens when returning to
the existing macOS 27 renderer. No such backend change has been accepted or implemented.
A native connection with unverified AirPlay mode leaves
the transport evidence/decision rule above open.
Keep measured findings and proposed departures here. Once the design is accepted, preserve
its isolation and renderer boundaries; a necessary change requires an explicit design
decision. Update this plan and move
it to `plans/done/` in the PR that completes the feature.

The first inexpensive `AVPlayer` media-source experiment is now built: generated PCM in
the decoder's format is packaged as complete temporary lossless WAV/CAF assets and loaded
through the same native picker/player. Local playability and the fresh-baseline HomePod
listening tests passed for both formats. This establishes the generated media-format boundary.
The actual-decoder experiment described above also passed local conversion, build, silent
startup and one guided real-song listening run, with full-track size and cached preparation
costs recorded. A separate architecture investigation must now evaluate
end-to-end startup cost, seek/pause, queue/gapless clocks, incremental delivery if needed,
temporary-file cleanup and safe transitions between outputs.
A complete-file test does not prove live PCM delivery or select a production architecture.

That next design must make the renderer/player handoff concrete: prepare a real media
item and bind its `AVPlayer` before route selection; define which backend plays before,
during and after selection; transfer the current position and clock without overlapping
audio or restarting the track; and define returning to the local renderer on deselection.
Define an authoritative position source and how receiver buffering/presentation offset affects
both directions of handoff. Give backend exclusivity and audible gaps separate pass criteria.
Choose the complete-file/preparation strategy or investigate incremental delivery before
queue/gapless design, with measured storage and startup budgets. Define ownership of normal
player state, Spotify Connect, Now Playing, remote commands and interruptions across the switch.
None of those product handoffs was exercised by the complete-file probe. One subsequent
receiver power-loss observation stayed silent while the sampled player clock advanced.
Other loss modes and controlled reconnection/resume remain untested. The gate preventing
audible local fallback is an **unverified product design requirement**; the bounded result
does not establish a platform guarantee or an implemented hold policy.
The earlier standalone fixture probe omitted the keychain entitlement and used a different
process model. The real-song experiment retained the ordinary app identity/entitlements, but
its separately controlled AVPlayer still does not exercise a production backend handoff.

## Verification

### Native picker fixture (completed)

- [x] The signed sandboxed app selects Küche HomePod through `AVRoutePickerView` attached
      to a real `AVPlayer`, without Control Center selecting the Mac's output.
- [x] The user hears the bundled tone on HomePod and confirms other sounds remain local.
- [x] Audio and alert output IDs remain on the Mac at all five sampled stages.
- [x] Capture during playback confirms no AirPlay HAL device/manager or player output UID
      was exposed for transfer to the existing renderer.
- [ ] Validate production Spotify delivery and playback transitions through a separately
      designed `AVPlayer` path, if that architecture is accepted. The disposable complete-track
      decoder experiment below does not implement those transitions.
- [ ] Record receiver software and modern AirPlay evidence; measure route loss, buffering,
      latency and cleanup. Repeat initiation without restarting the receiver. Any proposed
      `AVPlayer` backend must pass its own gate preventing audible local fallback on loss.
      The fixture result does not pass those requirements.

### Renderer inheritance fixture (negative result)

- [x] The user confirms production-renderer B stays on the Mac with A playing on HomePod
      and with A paused while its item remains loaded.
- [x] The renderer source fingerprint matches; B's feed and clock remain active without
      a captured issue/stall. Silence was not used as the negative routing observation.
- [x] Record the alert-default change between preparation and the local baseline; preserve
      the full-run changed flag rather than claiming a complete isolation pass.

### Complete PCM asset fixture (completed for generated assets)

- [x] Create actual WAV/CAF containers preserving all generated Float32 stereo samples;
      independently check channel order and a partial final chunk in tests.
- [x] Both complete 120-second assets pass AVPlayer playability/duration and item readiness
      in the signed sandboxed app, without a Play command.
- [x] Exercise explicit fresh baselines, format/observation resets, persisted load failure,
      recovery and normal temporary-asset cleanup in the silent runtime.
- [x] User confirms each container's tone plays on HomePod while Safari YouTube and a
      system alert preview stay local concurrently; all 45 sampled audio/alert defaults
      remain on the Mac against the two fresh baselines.
- [x] User confirms audible pause/resume for both. WAV seeks completed while paused and
      resumed afterward; CAF continued automatically after a seek while playing. Reports
      corroborate the respective states/positions. Identical pulses cannot establish an
      exact content position at the receiver.
- [x] Investigate complete-file actual decoder delivery in the separate real-track experiment
      below; the generated fixture itself supplies no Spotify/live PCM/gapless/route-loss proof.
- [ ] Design and accept a production backend separately from these complete-file experiments.

### Actual Spotify decoder experiment (local and bounded hardware checks passed)

- [x] Convert the existing real Vorbis stereo fixture through the unchanged production decoder
      into actual CAF; 10 checks cover channel content, sample-byte preservation, frame/duration
      agreement, partial final chunks, invalid input, existing-file preservation and cancellation.
- [x] Build and strictly verify the signed sandboxed disposable app; confirm decoder and
      current-renderer source fingerprints. Full copied app unit suite passes 630/630.
- [x] Silent signed mode: item ready/paused at zero, explicit baseline, cleanup, reopening
      invalidates controls, re-preparation requires a fresh baseline, and closing during a
      baseline action leaves no active run. No Spotify login or audio is initiated.
- [x] Prepare an actual Spotify song in the app; record full-track decoded/metadata duration,
      file size and preparation timings with verification overhead and the network/decryption
      exclusion explicit. Require decoded/metadata duration within 1 second as an exploratory
      spike criterion; investigate a larger difference before treating the run as a pass.
      This tolerance is not an assertion of a codec or Spotify trimming rule. The one-track
      duration delta is approximately 0.22 ms; CAF storage 74.3 MB and verification-inclusive
      cached preparation 0.94 seconds.
- [x] User confirms local baseline, then music on HomePod only while unrelated app sound and
      an alert stay local concurrently; all 17 pasted captures retain Mac defaults.
- [x] Confirm audible pause/resume and an active recognizable seek without a separate Play
      request. The automatic post-seek captures corroborate continued player advancement.
- [ ] Use the measured result to decide whether to design a production AVPlayer backend;
      this probe does not implement handoff, queue/gapless clocks or route-loss isolation.

### Receiver loss and deselection observation

- [x] Strict signed build, 12 recorder/monitor and 10 converter checks, source review and
      muted silent lifecycle checks pass. All 630 copied app unit tests pass. Silent mode
      uses a bundled fixture and skips account authentication; its 27 complete reports
      remain paused at position zero, muted and at zero volume. No route or Play request
      was made. This is not a receiver-loss hardware result.
- [x] User confirms HomePod playback, then deliberately selects Mac while recording; retain
      audible destination, notification ordering and sampled output defaults. One run
      returned audio to Mac with switches described as fast; exact gaps/overlap unmeasured.
- [x] User confirms HomePod playback, then disconnects receiver power while recording;
      retain whether music falls back to Mac, stops, stalls or behaves otherwise, including
      changes during the window. User heard silence with no Mac return. All samples kept
      playing/advancing without loss notifications; approximately 49.45 s followed the
      pre-unplug marker. No manual destination change or restart was instructed during loss.
- [x] Save separate completed traces and listener observations before
      another preparation/baseline resets the run. Do not treat a finite negative result as
      proof of product loss protection or a guaranteed early notification.

### Required before product implementation

- [ ] The signed-app **HAL/receiver** hardware gate passes from an idle receiver, with no
      Control Center connection prerequisite, and its evidence is recorded above. The
      native `AVPlayer` fixture does not pass this current-renderer gate.
- [x] If the signed inventory repeats the current absence of AirPlay managers/endpoints,
      record failure and stop before implementing a connection or PCM prototype.
- [ ] Küche HomePod is the first receiver tested. Record its software version and the outcome
      of the AirPlay evidence rule, including any deferred decision. A generic HAL AirPlay
      flag is not sufficient version evidence; an unresolved decision still blocks product work.
      Receiver software is now reported as 27.0 (24J361), model code MY5H2D/A; negotiated
      wire mode and the transport decision remain unresolved.
- [ ] The implementation has no AirPlay 1/legacy RAOP compatibility fallback and retains
      the macOS 27 receiver API.
- [ ] A protected or unavailable receiver fails with a useful error through supported APIs.
- [x] The gate runs with Spotifly's existing sandbox entitlements, or documents a specific
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
Product code was not changed. The separate diagnostic app was built, signed and run; its
twelve classification/default-comparison checks passed. The user verified native `AVPlayer`
AAC initiation and audible isolation after a HomePod restart. The subsequent two-tone app's
22 checks and silent startup passed; the user observed no production-renderer route
inheritance with A playing or paused, with the stale-baseline caveat recorded above.
The complete PCM asset probe's 22 checks, strict signed build and silent runtime also
passed on 2026-10-07. The subsequent user-guided WAV and CAF listening runs passed
HomePod playback, concurrent Safari/alert isolation and audible pause/resume; 28 WAV
and 17 CAF captures retained Mac defaults. Paused WAV seeks and an active CAF seek
are recorded separately, without an exact receiver-content-position claim. Source review
found no remaining actionable blocker within that spike after recovery fixes. Its local
validation record and raw smoke logs stay in the workspace outside this repository.
Current-renderer initiation was not demonstrated. The subsequent real-song experiment
passed Spotify playback through AVPlayer AirPlay for one cached complete-track CAF, with
concurrent Safari/alert isolation, audible pause/resume, an active recognizable seek, 17
unchanged sampled defaults and measured cached preparation/storage. Production handoff
and receiver-connection cleanup remain untested. Markdown structure,
local repository links and `git diff --check` passed. The repository remains documentation
only. Separately, the actual-decoder source snapshot's signed strict build, 10 converter checks,
630 copied app unit tests, SwiftFormat lint and signed silent runtime passed. A first test
runner timed out before connection during macOS startup permission; the first connected run
found one localization failure in experiment labels, fixed before the passing full rerun.
Source review also found and then cleared close/reopen and in-flight control races. The
guided real-song hardware result is recorded separately from fixture smoke above. Raw
reports and the sanitized local listening record remain outside this repository.

The subsequent passive observation build passed its final strict Release build, Developer ID
verification, 22 focused checks, all 630 copied app unit tests and SwiftFormat lint (0/18
files require formatting). The unit-test host is separately ad-hoc signed; it is not the
sandboxed listening-app identity. Final signed fixture-only smoke exited successfully with
27 complete reports and 130 recorded player states including events/watch samples, all
muted, paused and at zero volume/position, no errors and empty stderr. Synthetic item
notifications checked observer scoping; no Play request or route selection was made.
Source review found three cleanup races: an old monitor closing a reopened run, ownership
changing during a conversion join leaving preparation busy, and stale preparation completion
clearing a replacement conversion task. Ownership/generation guards and cancellation/join
cleanup fixed them; deterministic regression checks failed before and passed after the fixes.
The stale-completion check exercises the completion guard and actual replacement-task
cancellation/join, not full decoder scheduling. Focused re-review found no remaining Critical
or Important issue. Decoder/current-renderer fingerprints remain unchanged. Passive watch
expiry/stop does not pause or reroute playback. No overnight hardware test was performed.
The user explicitly resumed on 2026-10-08; both bounded listening cases above then completed.
The author preserved and checked the final report emitted in the launch log: two expired windows,
190 unique watch entries, 181 unchanged-default polls, 23 unchanged full captures, persisted
Mac/Silence observations, no natural end and unchanged source fingerprints. The final manual
capture was paused; the watch samples supply the earlier playing-state evidence. These are
read-only hardware-report checks, not fresh build/unit-test runs or product handoff tests.

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
document checks were run separately by the author. That review preceded both signed probes;
their subsequent HAL failure and native-player success are recorded above. Connection
feasibility with the current renderer remains unproven, and the HAL candidate is stopped
on this setup.

On 2026-10-04, Claude reviewed a redacted, text-only summary of the new hardware findings
and proposed conclusions, with tools/file access disabled. It found the conditional plan
consistent and requested tighter wording on the single successful run, sampled UID/HAL
observations, app configuration, system-owned protocol negotiation and separate player
route-loss/media-source gates. Those qualifications are included. This follow-up reviewed
the supplied conclusions only; Claude did not inspect the final document, recheck the SDK,
reproduce the hardware test or verify Spotify integration.
That follow-up preceded the two-tone experiment; its subsequent negative observation and
baseline qualification are recorded separately above.

On 2026-10-07, Claude reviewed a redacted technical summary of the complete PCM asset
experiment and next-step conclusions, with tools/file access disabled. It found them
internally consistent and mostly well scoped, while stressing that this is only a narrow
container/format test and does little to resolve actual Spotify delivery. The plan now
states that motivation, limits results to Float32, and explicitly requires unrelated audio
to play concurrently with the HomePod tone. Local asset equality is not a wire-format
claim; route-loss behavior remains unknown. The earlier AAC report's baseline was captured
at 07:42:24 Europe/Berlin, with Play at 07:42:34 and the last capture at 07:44:00; its fresh
two-minute sampling interval is distinct from the inheritance test's six-hour stale baseline.
The tested HAL/inheritance candidates remain stopped as project decisions for this
configuration, not universal API impossibility claims. The probe uses the earlier stated
sandbox/network/file permissions and omits the unused provisioning-restricted keychain
group; this is not an exact production-entitlement reproduction. Claude did not inspect
code, SDK, final document, UI, signatures or hardware and took check results as reported.

After the 2026-10-07 WAV/CAF listening runs, Claude reviewed another redacted technical
summary with tools/file access disabled. It found the fixture conclusion mostly consistent
and well scoped, and supported a real-decoder experiment rather than a backend change.
Its technical qualifications are incorporated: seeks differ by test procedure rather than
format, 30 seconds is player-reported, isolation was confirmed separately in each run,
backend/clock handoff and deselection are untested, route-loss protection is a design gate,
and probe/product configuration differences remain explicit. The final tested build was
used for listening and the report run IDs correlate with its launch log; no source change
occurred between them. This review did not inspect the final document, source, SDK,
signatures or captures, and did not independently verify hardware or Spotify integration.


Claude then reviewed a redacted summary of the real-decoder experiment with tools/file access
disabled. It supported a user-guided real-song test after the close-race smoke passed, and
asked for explicit whole-input/offset parity, same-decoder readback scope, listener evidence
and verification overhead. Source inspection confirms this pipeline already completes its
whole HTTP 200 download before caching and uses the same post-page-removal Vorbis bytes;
the summary review's hypothetical progressively filled cache does not describe this code.
The report/criteria now state the cached byte range, duration-difference check, same-decoder
CAF-integrity scope and verification-inclusive timing. Audible HomePod-only output and
recognizable seek behavior must come from the listener, not player readiness/time. The final
signed close-race smoke passed. Claude did not inspect source, signatures, SDK, final document
or hardware and took the supplied check results as facts.

After the real-song run, Claude reviewed only a **generic hypothetical native-picker/player
validation scenario**, with no project details, test measurements, source, raw reports or
hardware identities supplied and tools/file access disabled. It found the bounded listener
inference and design-before-integration approach reasonable. Its useful qualifications are
incorporated: isolation belongs to the tested player, same-app sources and brief local bleed
were not checked, the backward-seek result does not establish receiver accuracy, sampled
settings are distinct from audibility, and clock/command ownership and receiver-loss behavior
need explicit evidence and pass criteria. It recommended observing loss/deselection before
choosing protection logic. This was a reasoning review, not independent verification of the
actual Spotify test, its metrics, final document or implementation. The user's observations
and the author's local report/log checks supply that run's evidence.

Claude also reviewed a **generic hypothetical passive observer** with no project facts,
source, reports, measurements or hardware identities supplied and tools/file access disabled.
It accepted a bounded observational experiment and emphasized indirect routing evidence,
picker presentation versus selection, buffering/scheduling limits, natural completion,
case/trial scope and listener evidence. Those qualifications are recorded above. It did not
inspect or verify this build, local test results, document or physical receiver behavior.

A further generic reasoning-only Claude review on 2026-10-08 received no project facts,
code, hardware outcomes, measurements or identities. It distinguished a finite observation,
notification observability, a tested hold policy and guaranteed absence of fallback. Its
useful qualifications are included: the pre-action recording time does not count as
post-loss coverage, a reactive pause can race with fallback, and reconnect/network loss
are separate cases. It did not review the actual report, screenshot, source or final plan.
