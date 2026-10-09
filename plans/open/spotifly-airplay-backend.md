# Keep one Spotify player while switching between Mac output and AirPlay

Status: **Open**, 2026-10-09; proposed design in [PR #202](https://github.com/ralph/Spotifly/pull/202).
The user requested this design and a Claude review. Product implementation has not started.
The disposable one-song handoff prototype is built and silently verified. Moving its AirPlay
controls into a separate Speakers panel resolved the user's picker-opening symptom; the user
confirmed switching to HomePod, ordinary pause/play and, after the picker lifetime correction,
working seeking. Picker volume works, but bar volume still has no audible effect. A stale
SwiftUI volume-slider focus mask is reproduced and corrected with an AppKit slider in the
disposable prototype; its focus, keyboard and accessibility checks pass. The volume-command
report and live visual retry remain pending. Carried audible position and return remain
unconfirmed. Receiver-loss
protection, production startup/storage budgets, queue/gapless and transport evidence remain open.
Components: `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`, `Spotifly/SpotifyPlayer.swift`,
`Spotifly/SwiftLibrespot/Connect/SpircController.swift`,
`Spotifly/Store/PlayerModel.swift`, `Spotifly/Store/LoggedInSession.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/Views/SpeakersView.swift`,
`Spotifly/Views/AirPlayRoutePickerView.swift`; proposed native-player adapter,
PCM asset preparation and output service; tests and localizations.
Found: 2026-10-08, after app-only playback of a real Spotify song and bounded receiver-loss
observations, the user requested the next integration design.

## Summary

Keep the macOS 27 `AVSampleBufferAudioRenderer` and its asynchronous receiver for ordinary
Mac output. Add an `AVPlayer` path for native AirPlay. Switch paths inside the existing
`AudioPipeline`, keeping one track, queue, Spotify Connect identity and command owner.

For the first prototype, use the complete Float32 PCM CAF candidate already exercised by
the disposable probes. Prepare it while the old path continues, then pause that path,
capture its position, retire its decode loop, seek the new path while paused and commit
ownership before resuming. Apply the current stream gain before either path starts.
Sender exclusivity and audible handoff quality have separate acceptance criteria.

The proposed Speakers flow has two explicit actions: **Use AirPlay** prepares and switches
to the native player; its bound native picker then selects the destination. **Return to Mac
output** switches back to the existing renderer. Preserve play/pause intent across each
successful switch. Until a receiver is selected, the native player can play on its current
route, including locally. Dismissing the picker, cancelling selection or selecting Mac in
the picker does not switch backends. This two-step entry is a proposed UX choice, not an
shipping product behavior. It is now implemented only in the disposable prototype.

Do not claim that entering this mode means a HomePod is connected. Do not infer a route
from a picker callback, discovery flag, player clock or readiness. The bounded power-loss
test heard silence while the player's clock advanced. A supported way to prevent unexpected
local fallback is still a release gate; this design does not invent a receiver-loss event.

Read the [feasibility and hardware record](spotifly-only-airplay.md) for the evidence. Its
HAL design is conditional historical reference, not this design's implementation path.

## Problem

### What the current code owns

- [AudioPipeline](../../Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift) owns the loaded
  compressed track, decoder, serialized transitions, renderer-relative position and
  continuation into the next track. Its sink is the concrete `AudioRenderer`. The download
  and decryption already produce complete Vorbis bytes; the CAF candidate adds full decode
  and disk storage, not a new Spotify download protocol.
- [AudioRenderer](../../Spotifly/AudioRenderer.swift) owns macOS 27 buffer enqueue, the local
  render clock, stream gain and default-output recovery. Those clocks and recovery tasks
  cannot remain active playback authorities while `AVPlayer` owns the song.
- [LibrespotClient](../../Spotifly/SwiftLibrespot/Public/LibrespotClient.swift) owns the queue,
  local versus mirrored state, pipeline events, position cache and ordered Connect reports.
  Both UI and incoming Connect transport commands already reach this pipeline. A backend
  switch must not call `play(uriOrUrl:)`, claim a different device or rebuild the queue.
- [SpotifyPlayer](../../Spotifly/SpotifyPlayer.swift) is the app's command facade. Its
  `setOutputVolume` currently addresses the renderer directly, separately from logical
  Connect volume. Updating only the pipeline's transport methods would leave AirPlay gain
  uncontrolled. [PlaybackViewModel](../../Spotifly/ViewModels/PlaybackViewModel.swift)
  applies that gain, follows `PlayerModel` and updates Now Playing and position anchors.
- [PlayerModel](../../Spotifly/Store/PlayerModel.swift) receives coherent `PlayerSnapshot`s.
  Views must continue to use it for playback state. The picker needs a MainActor reference
  to the actual native player, not a second view-owned player or a second playback model.
- [SpeakersView](../../Spotifly/Views/SpeakersView.swift) currently enables AirPlay by device
  name. Use device ID and local capability instead. [AirPlayRoutePickerView](../../Spotifly/Views/AirPlayRoutePickerView.swift)
  currently has no player binding. [DeviceService](../../Spotifly/Store/Services/DeviceService.swift)
  transfers Connect ownership; AirPlay mode is a local output change, not such a transfer.

### Public API boundary

Checked against the installed Xcode 27.0 macOS 27.0 SDK on 2026-10-08:

- `AVRoutePickerView.h` accepts `AVPlayer` through its macOS `player` property. Its
  sample-buffer renderer support is explicitly for iOS/tvOS. Its two delegate callbacks
  describe presentation only. The color getter takes a supplied button state; it does not
  reveal the current route. There is no public macOS presentation method in that header.
  Use the actual native view after preparation; do not synthesize clicks or inspect its
  private subviews. See [picker/player](https://developer.apple.com/documentation/avkit/avroutepickerview/player)
  and [delegate](https://developer.apple.com/documentation/avkit/avroutepickerviewdelegate).
- `AVRouteDetector.h` reports whether another route is discoverable. It does not identify
  the selected receiver or report that receiver's loss. Optional detection can run while
  Speakers is visible and must stop afterward because of its power cost. It cannot gate
  safety or be the sole reason to disable the picker. See
  [AVRouteDetector](https://developer.apple.com/documentation/avfoundation/avroutedetector).
- A completed [AVPlayer seek with zero tolerances](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:))
  requests sample accuracy and can add delay. An interrupted seek completes with `false`.
  Wait for success and verify item/generation before resuming. This is a media-clock
  condition; it does not measure when HomePod renders the sample.
- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer) exposes item
  time, playback controls and per-player volume. Pause does not supply a remote-buffer
  drain acknowledgment. Do not claim that a sender pause or exact seek proves zero
  acoustic overlap, continuous listening or receiver presentation accuracy.

The prior probes found no usable output UID or selected-audio-route signal. An
audio-only remote stream also did not make the external-video playback flag useful.
The complete-file results establish a media-source candidate, not a production output policy.

## Solution

### Decision inventory

| Choice | Status and recommendation | When it must be resolved |
| --- | --- | --- |
| OS and local renderer | Settled: macOS 27 only; retain `Receiver.enqueue(_:) async`, Spatial Audio settings and local recovery. No legacy sender or renderer API. | Preserve throughout. |
| Native routing and source | Proposed: a second `AVPlayer` path using complete Float32 CAF and the native picker. HAL/inheritance candidates failed on the tested setup. | Accept before the handoff prototype. |
| Playback ownership | Proposed: retain `AudioPipeline` and `LibrespotClient` as the single control/queue owners; choose one output within the pipeline. | Before coding the prototype. |
| Entry, cancellation and return UX | Proposed: explicit mode entry, then native picker; explicit return. Preserve intent, accept possible local music before receiver selection. Picker cancellation leaves the mode and native route as they are. | User review of this design. An entry that holds until explicit Play is the alternative below. |
| Handoff clock | Proposed: transfer a frozen source media position; destination seeks while paused. Receiver presentation offset remains a measured limitation. | Prototype establishes feasibility; audible criteria below must pass. |
| Unknown receiver loss and local fallback | Unresolved factual gate: find supported observability with adequate ordering, or a preventive platform contract. Never invent a loss signal or treat one silent trial as a guarantee. | Before a production implementation/rollout. |
| CAF startup, storage and cleanup | Complete-file candidate for one-song prototype; production duration/size limits, uncached latency and prefetch budget unresolved. | Measure in prototype; choose budgets before queue work. |
| Queue/end/gapless | Deferred: retain one queue; prototype stops held at the current song's end and rejects changes to a different track. Production needs backend-specific continuation. | Separate design after handoff and budget evidence. |
| Reconnect, takeover and sleep | Proposed lifecycle policy below; automatic resumption after receiver reappearance remains unsupported. | Prototype tests known lifecycle events; production loss/reconnect gate remains. |
| AirPlay version requirement | Settled: prefer the current native stack; no legacy compatibility implementation. Negotiated mode remains unknown. Strict AirPlay-2-only enforcement versus accepting opaque native negotiation is still a user decision in the feasibility plan. | Resolve before release; do not silently relax it here. |

All backend interfaces and flow below are proposed. They are concrete enough to review,
but are not authorization to change the application or evidence that the release gates pass.

### Options and scope

The recommended dual-path design preserves the existing local renderer, decoder and queue
and uses the media-source boundary that the probes exercised. A single `AVPlayer` for every
output would simplify switching but would replace local pacing, recovery, Spatial Audio and
gapless behavior without evidence. It does not remove the native route-observability limit.
Do not choose that global replacement for this work.

Incremental media delivery could reduce CAF delay and disk use. A resource loader, segment
pipeline or custom streaming format would need its own AVPlayer playability, range, seek,
end-of-stream and cancellation experiments. A progressively written CAF is not assumed to
be a supported streaming asset. Use complete files to isolate handoff first; reconsider the
source if measured costs make the production budgets unacceptable.

The smaller UX alternative is to keep the new player paused after mode entry and ask the
listener to select a receiver, then explicitly press Play. It avoids starting the new player
before that confirmation, but adds a step and changes the original playing intent. It still
cannot establish selected-route identity or protect against later fallback. Recommend
preserving intent for the supervised prototype; keep this alternative visible for user review.

The next build is a disposable copy with an explicit experiment switch. It adds normal
pause/resume, same-track seek, stream gain, Connect controls for those operations and output
handoff for one loaded song. It is not a released AirPlay feature. Unsupported new-track
commands must be rejected before queue mutation while this mode is active, including remote
Play/Next/queue-row commands. Previous may restart the same song but must not load a prior
song. At end, hold the current song at its end without calling ordinary auto-advance or
looping repeat. Return to Mac output restores ordinary queue behavior. These restrictions
are visible in the experimental UI and inert outside the experiment.

### Responsibilities and concurrency

Keep the local decode implementation in `AudioPipeline`; do not force a complete-file
player through the renderer's PCM `enqueue` protocol. Add the following narrow boundaries:

| Owner | Responsibility |
| --- | --- |
| `AudioPipeline` actor | Output mode, track/source identity, desired play/pause state, transitions, clock selection, generation checks, source retirement and end events. No change to queue ownership. |
| Proposed `NativePlayerOutput` on `@MainActor` | One `AVPlayer`, item preparation/readiness, seek completion, transport, stream gain, clock samples, item observers and disposal. Receives qualified requests; returns `Sendable` results/events. No queue or Connect logic. |
| Proposed `PCMAssetPreparer` off MainActor | Fresh decoder over immutable prepared Vorbis bytes, complete CAF write, format/frame/duration validation, cancellable work and temporary asset lease. Never shares the active mutable decoder or writes playback state. |
| `LibrespotClient` actor | Owns pipeline lifetime, validates local ownership/capability, consumes its ordered events, publishes playback and output state together, updates position cache and sends Connect reports. |
| Proposed `AudioOutputService` on `@MainActor` in `LoggedInSession` | Calls facade commands and makes the qualified picker binding available. Holds no separate playback truth. Session lifetime survives window closure. |
| `PlayerSnapshot` → `PlayerModel` | Published output mode/phase and recoverable failure, alongside existing playback/queue state. UI renders these facts; no AVPlayer state subscriptions in the view model. |

The pipeline creates/owns the native adapter through a MainActor factory. Its picker
binding is registered with the signed-in session's output service using the same pipeline
generation. The binding exposes the adapter's actual player for `NSViewRepresentable` only.
It is separate from the Sendable snapshot. MainActor isolation permits holding/passing the
adapter reference without transferring mutable AVPlayer state between actors or adding
`@unchecked Sendable`. Clear the binding when that pipeline/session is replaced, and set
the native view's `player` to `nil` when dismantled. Closing a view releases its binding,
not the live output. Do not create the player in `makeNSView`.

Adapter operations need explicit contracts: prepare a leased asset paused; seek and return
completion plus the final media position; pause and sample the frozen position; apply the
latest gain; resume; observe status/time/end/error; dispose and release the item. Carry a
session/pipeline ID, track generation, handoff generation and item ID on asynchronous work.
An item callback is valid only for the current owner and matching IDs. A stale callback
may release its own resource but cannot change current state or dispose a newer item.

Keep the existing short serialized transition gate for the commit and transport operations.
Prepare files outside it, so Pause, Stop and Connect takeover do not wait for full decoding.
The commit checks current identity and command revisions again after every awaited backend
operation. Cancellation is a request: await conversion/decode retirement before releasing
their resources. Do not leave a preparation task holding the transition gate while waiting
for a callback that needs that same gate.

### State and control rules

Proposed snapshot data consists of an output mode (`mac` or `nativePlayer`), phase
(`ready`, `preparing`, `switching`, `waiting` or `held`), and optional recoverable failure.
These names describe the app's owner/state, not a selected receiver. The native picker
shows route names. Route certainty remains unknown unless a supported API establishes it.

| Phase | Source of position | Playback rule |
| --- | --- | --- |
| Preparing | Current owner | Old output follows all current controls; preparation cannot play. |
| Switching | Frozen source position | Both outputs held; retain the latest user intent, expose buffering for Play intent and publish rate zero. |
| Ready | Committed owner | Resume only if the latest intent is playing. Pause remains paused. |
| Waiting | Native item media time | Describe buffering, freeze interpolation when the media clock stops and retain intent. A documented waiting state is not proof of receiver loss. |
| Held/error | Frozen last valid media position | Keep track and queue, report paused and show why. Only explicit Resume or an authorized output switch can restart. |

Pause during preparation updates intent without restarting conversion. Seek updates the
source and the eventual frozen handoff position; do not copy the position captured when
preparation began. Volume writes update a revisioned gain cache. Stop, session replacement,
Connect stand-down, a new track or newer output request invalidate preparation/commit.
A second output request supersedes the first; it cannot commit after the new request.
During the short commit, queue controls wait or supersede through the same command revision
policy; no delayed Resume may override a newer Pause or Stop.
Register command revision and changed intent when the command enters the pipeline actor,
before it waits for the transition gate. The gate serializes backend effects, not command
admission; otherwise a Pause queued behind an awaited seek could arrive too late to prevent
the old intent from resuming.

Extend ordered pipeline events with qualified output/phase changes. On a switch, publish
output mode, frozen position and corresponding playback state in one client snapshot.
Do not announce running playback merely because a file is readable. A preparation failure before
source retirement leaves the old owner usable. A failure after retirement holds the track
with a recoverable output error; it must not use the generic error path that clears local
state/queue or silently restore local sound. Existing track/content errors keep their
ordinary semantics. Re-anchor on commit, completed seek and transport-state changes.
Retain a handoff record with target mode, source identity, frozen position and intent until
commit or explicit recovery. With no usable owner after retirement, return that frozen
position from the cache. Generic Resume must not revive the retired source; offer Retry
for the recorded target or Return to Mac output. Retry is a new generation and forward
transition, with the latest user intent. Held output errors remain visible until recovery.

### Entry into native AirPlay mode

1. `Use AirPlay` checks a connected playable local session, owned device ID and a loaded
   local track. A remote device named “Spotifly” does not qualify. Disable with useful text
   for authorization/Premium, mirrored playback or a pending Connect transfer. Do not
   implicitly take playback from another Connect device.
2. Start a cancellable CAF preparation for the current prepared track/quality and create a
   paused native item. The local renderer continues following normal commands. Show progress
   and offer cancellation while preparing. The native picker is disabled until its exact
   player/item is usable and native ownership is committed; the wrapper updates its binding
   rather than remaining empty. Cancelling preparation before retirement leaves local
   playback and its current intent intact.
3. In the commit gate, verify track/session/request identity. Pause the renderer and read its
   frozen track-relative frame before stop/flush resets the clock. Retire and await the
   decode loop and pending continuation/refill work. Stop/flush the renderer. No new PCM
   enqueue, local stall recovery or continuation may run for the inactive mode.
4. Seek the paused native item to that captured position with zero tolerance. Require a
   completed seek on the same item and a finite, clamped position. A `false` completion from
   a superseded seek is ignored; a current seek that cannot finish leaves the switch held
   with an error. Apply the latest tapered
   gain before committing. If anything is superseded, keep both held and let the newer
   command establish the outcome; do not revive the old intent.
5. Commit native ownership and its clock, publish the coherent transition, then resume
   only for the latest playing intent. A previously paused track stays paused. Preserve
   track URI/market ID, queue row UID/context, options and Connect ownership.
6. Expose the actual native picker. The listener clicks it and selects HomePod. The UI
   explains: “Music continues on its current output until you choose a speaker.” Keep the
   separate Return action available. Do not attempt private programmatic presentation.

There may be a brief gap between step 3 and step 5. The prototype must measure it. Do not
promise a gapless handoff. A click that opens/closes the picker, including a cancelled or
failed native connection, causes no automatic backend switch or playback-state change.
Without a supported native failure signal, leave connection errors to the native UI rather
than manufacture a successful connection status. Selecting the Mac in that picker routes
the native player locally, without changing the backend or implying that the old renderer
resumed. Repeated picker opens use the same active player/item.
Requesting the already committed mode is a no-op; it must not reconvert or restart the song.

### Return to Mac output

This action deliberately resumes following the **macOS default output**, as ordinary
Spotifly does. It does not select built-in speakers or change audio/alert defaults. If the
user globally selected a network output in Control Center, this action is not a guarantee
of built-in/local sound; the UI must describe the default-output behavior.

Pause the native player and capture its finite item time while it is still the current
owner. Invalidate its transport callbacks, then stop/release its item before starting the
renderer. Keep the compressed source alive. Seek the local decoder to the corresponding
frame, rebuild local clock origin, restart held, and preroll PCM with the current gain.
Commit local ownership and resume only for the latest intent. A native item that is already
held stays held unless this explicit action also has playing intent. Do not redownload or
start at zero. A failed return remains held with an error, rather than reviving AirPlay or
starting local playback from an unknown position. Detach the picker binding only after it
can no longer control the retired player.

Renderer `playedFrames` measures its media clock. Native `currentTime()` measures item
time; it is not a verified HomePod presentation clock. Do not add an assumed AirPlay latency
to either direction. If an unobserved loss lets native time advance through silence, an
explicit return carries that advanced media time; the app cannot reconstruct the last
sample the listener heard. Record sender pause, captured time, destination seek completion and
resume with monotonic timestamps. Measure acoustic tail/gap separately. Remote buffering
may leave a tail even after native pause; exclusive sender ownership cannot guarantee that
the HomePod has stopped emitting before Mac sound starts. If the proposed audible criteria
fail, hold the return for explicit user continuation or investigate a supported buffering
solution; do not disguise the problem with an arbitrary delay.

### Position, normal controls, gain and Connect

`AudioPipeline.currentPositionMs()` returns the frozen handoff/hold position or chooses the active backend. For the native player,
use a MainActor sample of its item time, converted/clamped to milliseconds. Keep a qualified
cached sample for synchronous facade reads; invalidate/re-anchor it during item changes,
completed seeks, waits and holds. The local path retains its current frame accounting.
Do not keep advancing the local renderer clock or decoded-frame counter behind native
playback. PlaybackViewModel's once-per-second drift correction and Now Playing consume the
same active clock and transport state, not a second native timer that writes UI directly.
Name native time as a media position, not a measured audible receiver position.

Normal bar, keyboard/menu, Now Playing and Connect commands still call `SpotifyPlayer` /
`LibrespotClient`. Same-track seek/pause/resume dispatch through the active pipeline path.
Spirc reports the Mac's existing ID, track, queue and options. HomePod is not added as a
Spotify Connect device. A handoff does not transfer the Connect role. Existing ordered
reports must take the committed output's fresh position and hold state, including reports
sent while a command completes. Add an explicit native transport projection to
`PlaybackState` and `SpircPlayerState`; output phase alone cannot fix report timing.
For native waiting or an internal handoff hold with Play intent, report an item present/playing, `isPaused = false`,
`isBuffering = true`, playback speed zero and its frozen position/timestamp. A user Pause
or an error requiring explicit continuation reports paused at the frozen position using the existing paused
Connect mapping. Native running reports speed one and clears buffering. Gate view-model
interpolation and Now Playing rate on that projection, while keeping the Pause action
available during waiting. Keep the existing local/mirrored mapping unchanged. Validate
these proposed native reports with a second client; the current Spirc code derives
buffering from Pause and has no independent native-waiting representation.

Make `SpotifyPlayer.setOutputVolume` apply its existing logarithmic taper to the active
native output as well as the local sink. Cache the latest gain with a monotonically
increasing revision; apply it on MainActor to native volume before first Play and after
each item preparation. A late gain task cannot overwrite a newer value. Muted/zero gain
remains zero through both handoffs. Keep one logical Connect volume and saved preference;
do not write HomePod/system volume. Test whether per-player gain actually works on the
selected receiver; native receiver volume shown by the picker is a different control.

For native waiting, publish buffering and a stopped media clock without converting the
user's desired Play into a new Pause command. Test the proposed Connect report mapping
in the prototype; when media progresses again, re-anchor and restore the running rate in
Now Playing. That path describes observable item behavior only. In the observed silent
power-loss case there was no such transition, so the UI cannot truthfully say “receiver
disconnected” or freeze the clock based on an assumed event.

### Receiver loss and lifecycle gates

The implementation must never choose the local renderer as an automatic fallback from
native mode. This controls the app's own backend policy. It does **not** stop AVPlayer itself
from changing its native route. A `pause()` called after an eventual error can race with
audible fallback. Native picker delegates, discovery, readiness and currentTime are not
a preventive isolation mechanism. Preserve the stronger product requirement from the
feasibility plan until evidence or an explicit user decision changes it.

Before release, establish either a documented native no-fallback constraint for audio or
supported selected-route observability with ordering/protection sufficient to prevent local
sound. Verify loss, network failure, receiver takeover and sleep/wake separately with audible
evidence. If no supported protection exists, leave this feature experimental or return to
the user with the specific guarantee that cannot be delivered. Do not replace that guarantee
with “works in a trial,” silent gain after detection or a private route API.

For an observable item failure, pause/hold, preserve track/queue and show a recoverable error.
Retry and Return are explicit. The prototype's power-loss test is a supervised observation,
not a demonstration that this policy handles all losses. Receiver reappearance must not
cause an app-initiated switch/resume; native automatic reconnection behavior remains to be
observed. An unknown loss cannot automatically create a truthful held state.

On Connect takeover/transfer away, Stop, logout or pipeline replacement: revoke generations,
pause both paths, retire decode/conversion work, unregister the picker, release native items
and observers, then remove leased files. Cancel pending seeks on the retiring item; ignore
their superseded completions. Remove periodic/boundary observers from the player that
created them and invalidate item observations before release. A stale callback cannot resume playback after
stand-down. Closing Speakers or the main window does not stop playback; the output service
belongs to `LoggedInSession`. Ordinary Spotify transport reconnection keeps the output when
the existing pipeline is retained. If the pipeline must be rebuilt, restore the saved track
held and require explicit continuation; do not silently default a prior AirPlay session to
playing on Mac. Test sleep/wake even when the Spotify socket reconnects independently.

### Complete-file cost and resource ownership

Use the existing prepared compressed bytes and a separate decoder to write the complete
lossless CAF off MainActor. Validate format, finite duration, frame count, successful close
and AVPlayer item readiness. Keep same-decoder full readback as a probe/diagnostic option;
it is not independent codec verification. Measure production preparation without that extra
readback too. Never run full conversion on the UI thread or share the playing decoder.

One 210.56-second cached track used 74.3 MB, with 0.94 seconds of preparation including full
readback. That excludes earlier download/decryption and is not a latency budget. Estimate
file size as frames × channels × four Float32 bytes, plus CAF overhead; bound duration,
overflow and disk allocation before writing. Measure short, long and uncached tracks,
quality changes, memory and disk peaks. The prototype keeps at most one CAF conversion and
one leased CAF item; replacing work awaits retirement before reusing that slot. Do not
prefetch a decoded queue until explicit byte/time budgets are selected.

Files live in an app-owned temporary directory with opaque names and no identifiers in
filenames. A lease remains valid until native item and pending seeks are released. Conversion
failure/cancellation removes partial files; disposal removes completed files. Cancel, await,
then clean up in that order. Startup cleanup removes only stale experiment-owned files not
leased by a live instance. Do not log compressed audio, decoded content or private account
data. Persist sanitized timings, state transitions and listener observations for review.

## Verification

### Checks for this design document

Check the four-section plan structure, relative links, component references and whitespace.
Read it against the current source, hardware record and the user constraints. Keep all
implementation/listening tasks below unchecked until they actually run. A documentation
change needs no music playback or new build/unit run.

Author checks passed on 2026-10-08: both Open plans have the four required sections; all
20 relative Markdown links and nine component paths in this design exist. Whitespace and
design-coverage checks passed. The source and installed-header inspection above informed
the self-review. This update changes only the two plans and changelog; no audio was started.

The requested Claude review must state its scope. Prior automatic approval review rejected
sending private project material externally. Use only a generic hypothetical architecture
and public API reasoning with tools/file access disabled, then assess its findings locally.
Do not claim Claude independently verified this source, document or hardware.

### Review of the proposed reasoning, 2026-10-08

Claude reviewed only generic public-API questions about output mode/destination, asynchronous
handoffs, media clocks, transport/gain, lifecycle and fallback. Its CLI had tools and file
access disabled. It received no project source, design document, hardware results, metrics
or identities. This is a limited reasoning review, not verification of the actual plan.

Local assessment incorporated its useful points: retain intent separately from mechanical
holds, freeze remote/Now Playing interpolation with rate zero, ignore superseded seek
completions, make post-retirement recovery a new explicit transition, and remove observers
from their original player before releasing the item/file. Preparation failure versus
post-retirement failure and gain-before-start are explicit above. Its receiver-buffer and
reactive-pause qualifications reinforce the separate acoustic and no-fallback gates.
It supplied no new selected-audio-route API or protection guarantee. Its unverified API
comments and generic export-reader examples are not evidence about this application's
decoder, assets or current SDK; source/header checks remain the author's responsibility.

### Disposable handoff prototype, 2026-10-08

The user authorized building this experiment. It lives outside Git in the workspace sibling
`spotify-handoff-airplay-experiment`, with a retained source archive of commit `6321396`,
integration script, tests and `build/Spotifly Playback Handoff.app`. Production source remains
unchanged. The prototype uses one pipeline-owned controller and the same facade/client,
snapshots, normal controls and Connect owner. The native picker binds to its actual AVPlayer.
Use AirPlay and Return to Mac are explicit; preparation preserves intent and current gain.
The same song is held at native end; unsupported new-track commands are rejected before
queue mutation. Entry is refused once local gapless continuation has begun; test earlier
in the song. Crash-startup scavenging is deferred; live item/file cleanup is implemented.

Silent author verification passed: 17 controller checks, 11 CAF converter checks, all 630
copied app unit tests, and 33 signed adapter/pipeline/client smoke checks. The strict Swift 6
Release build and signature verification passed; SwiftFormat 6.4 lint found no changes in
the 13 source/test and 20 generated integration files. The decoder and macOS 27 renderer
fingerprints match production. Native fixtures stayed paused at zero gain; renderer fixtures
were muted and held. No music, alert, route selection or disconnection was initiated.

A fresh local source reviewer found five Important issues, all reproduced then fixed with
silent regressions: existing/suspended continuation and queued refill crossing ownership,
stale AirPlay projection after stop/recovery, a refused return-preroll buffer releasing the
song, an awaited old failure overwriting a new position, and preparation failure disabling
normal Mac Resume. Tests passed after the fix pass; no second review or hardware result is
claimed. A minor display issue remains: a native paused callback can label an end hold ready,
while playback remains paused and native track changes stay blocked. Detailed local evidence
and rulings are in the sibling's `results/validation.md`; raw reports/code are not in this PR.

This adds no new audible or transport evidence. Receiver-loss protection, audible gap/tail,
carried audible position, receiver gain, queue/gapless and release readiness remain open.
Start the supervised session with a fresh Mac-default baseline, then a paused mid-song
entry and explicit receiver selection, normal Play, and an explicit return. The app's
Handoff experiment menu provides state markers and a saved/copyable listening report.

The first supervised attempt did not complete destination selection: the user reported no
response from the Speakers picker, then a briefly opened menu followed by loss of local
Connect ownership. Repeating with only the handoff app running still did not open the picker.
At that stage the cause was unresolved; this does not invalidate the earlier separate-player
listening results or establish a failure of AVPlayer routing itself.

The disposable diagnostic revision records picker clicks/lifecycle/presentation callbacks
and local Connect requests/ownership changes in a bounded local trace. A second native view
in the report window binds to the same prepared player for comparison outside the Speakers
List. Presentation remains user initiated and is not route evidence. A logging-induced
redraw loop was caught and corrected in silent validation before this build was offered.
Fresh verification passed: strict signed Release build, 17 controller checks, 11 converter
checks, 38 signed silent checks (including actual picker refresh/teardown and trace writing),
and all 630 copied app unit tests, with no failures or skips. Renderer/decoder fingerprints
still match production. That diagnostic build did not itself resolve the picker symptom.

The user's copied comparison report then showed eight Speakers mouse-down events with
`reachesPicker=false`, and two report-window opens with both mouse events reaching the
native view and its presentation delegate firing. Both views used the same prepared player;
it remained ready and locally owned, without a Connect transfer request or ownership change.
The report entered native mode while playing, so it does not verify paused entry, acoustics
or position carry. Its sampled Mac audio and alert defaults stayed unchanged.

Silent static/dynamic List layouts, including the actual controls, received native hits;
they did not reproduce the live interception. The exact intercepting view remains unknown.
The disposable revision moves the same AirPlay controls into a separate panel above
the Speakers List, following the working comparison's placement outside a list row. Click
traces now include the hit view's class and local coordinates if the retry fails. The strict
signed build, formatting and 40 silent checks pass, including dynamic panel hit handling and
preservation of the paused zero-gain item; all 630 copied app unit tests pass with no failures
or skips after retaining the original speaker hints. Silent checks alone did not establish
resolution of the live presentation symptom.

The user then confirmed that the revised Speakers picker opens and switches to HomePod.
The supplied screenshot shows that native menu open with Küche HomePod selected. This
resolves the reported opening/selection symptom on the tested setup; the precise intercepting
view in the old layout remains unidentified. Continued audible position, paused-entry intent,
normal controls, return to Mac, unrelated-sound isolation and heard overlap/gaps still need
qualified observations in this integrated prototype. No full handoff or release verdict follows
from opening the menu or its selection checkmark.

The next supervised check failed two controls: the native picker's volume changed HomePod
loudness, but the now-playing bar's volume had no audible effect, and seeking returned audio
to the Mac. The user subsequently said everything else worked, explicitly including
pause/play. Record ordinary pause/resume as a reported success; other unnamed controls and
the specific build/run are not identified by that follow-up. Keep the two failures separate
from the earlier standalone-player seek result.
Source inspection found that a native seek publishes `switching`, which made both picker
hosts disappear; their dismantling clears `AVRoutePickerView.player`. An actual signed,
paused, zero-gain fixture reproduced that detachment: the new regression failed on retaining
the bound Speakers picker through `switching`. Removing the transient-phase exclusion keeps
the same native view/player/delegate through switching, waiting and ready; all 44 silent
checks then pass. This establishes the UI lifetime defect and its correction, not that the
HomePod route survives a real seek. A fresh listening retry is required.

The bar's local gain path is present through facade, client, pipeline and controller to
`NativePlayerOutput.setGain`, which assigns `AVPlayer.volume`; receiver loudness is not
observable through that property. The old report is requested before diagnosing a missing
command versus ineffective native gain. The next disposable build records bar-command target,
accepted native gain/revision and seek item/position separately from listener observations.
No volume fix, receiver-volume API, or successful integrated seek is claimed.

The final control-diagnostics candidate passes a fresh strict Swift 6 Release build with
Swift/C warnings as errors, Developer ID strict signature verification, all 44 signed silent
checks and all 630 copied app unit tests (0 failed/skipped). Formatting is clean and the
production renderer/decoder fingerprints still match. It is packaged separately as
`../spotify-handoff-airplay-experiment/build/Spotifly Playback Handoff Controls.app`, keeping
the current experiment available for the failed-run report. Audible playback and route
selection remain manual. Production Git changes are documentation only.

### HomePod seek retry and volume-slider focus, 2026-10-09

The user confirms that seeking now works in the corrected candidate. Record this as a
supervised integrated seek success on HomePod after keeping the same picker/player bound
through the transition. It does not measure receiver presentation position or qualify all
handoff/return cases. The user still reports that only the native picker's volume changes
loudness, and supplies a screenshot of a blue ring left at the bar slider's former position.

A silent UI-only probe reproduces that ring's underlying defect on macOS 27: the SwiftUI
thumb moves from 30% to 80%, while its public `NSView.focusRingMaskBounds` remains at the
30% knob rectangle, even after `noteFocusRingMaskChanged()`. An activated app repeats the
failure. The candidate replaces only the disposable bar's slider with a standard `NSSlider`
representable, preserving its existing volume binding, green track, disabled state and
localized accessibility label. The native focus mask follows the thumb; a real dispatched
arrow key writes the binding, and the accessible slider cell and disabled state pass checks.
No private framework method is called and no user setting is changed.

The separate `../spotify-handoff-airplay-experiment/build/Spotifly Playback Handoff Slider.app`
passes a strict Swift 6 Release build with Swift/C warnings as errors, strict Developer ID
signature verification, all 44 signed silent handoff checks and all 630 copied app unit tests
(0 failed/skipped). Source/generated formatting passes (0/15 and 0/23); renderer/decoder
fingerprints still match production. The original and Controls apps are retained for the
current report. The volume path is unchanged: request the new bar-command/native-gain trace
before distinguishing missed commands from ineffective receiver gain. Live visual confirmation
and a HomePod gain fix are not claimed. Production source remains unchanged.

- [x] Add only the one-song experiment scope above. Keep ordinary production output behavior
  unchanged unless the experiment is explicitly enabled. Label incomplete loss protection.
- [ ] Test the transition controller with controllable backend fakes: one running owner;
  prepare/seek failure; Pause/Seek/Stop during preparation; superseded item/output requests;
  Connect stand-down while seek awaits; stale end/error/volume callbacks; item release before
  file deletion. Assertions inspect effects and published state, not copies of method logic.
- [ ] Exercise actual adapters silently, paused and with zero gain: finite clock, interrupted
  seek, same item binding, time observer removal, partial-file cleanup and cancellation
  joining. Strict Swift 6 Release build, signing/entitlements and focused tests must pass.
- [ ] Keep native/local gain equal through preparation, both handoffs and remote volume
  changes. Test mute, zero, low and ordinary volume on hardware with the listener's consent.
- [ ] Supervised listening: start on Mac, hand off mid-song, select only HomePod, hear that
  song there while Safari and an alert stay local; repeat from paused. Return explicitly,
  hear the same song at the carried position on the Mac default output. Check native-picker
  Mac selection/cancellation without a backend switch. Record fresh system-default baselines.
- [ ] Exercise bar/menu/Now Playing and a second Connect client's pause/resume/seek. Check
  that the track/context/row/options and Mac device identity remain the same. Transfer away
  stops both outputs and later callbacks remain inert. Reject unsupported track changes
  before queue mutation; verify natural end holds once without auto-advance or repeat.
- [ ] Provisional prototype criteria: paused handoffs emit no audio; destination media time
  after a completed seek differs from the frozen source target by at most 10 ms, except a
  duration-end clamp. No receiver/system gain jump, heard overlapping passages, unintended
  restart or unrequested local sound. Log actual gap/tail; a gap over 1 second prompts a
  redesign before queue work. These are proposed thresholds, not observed results or a
  release-quality definition. Hardware capture/listener notes supply audible evidence.
- [ ] Measure uncached preparation, conversion-only time, cancellation latency and peak
  storage/memory. Acknowledge receiver presentation offset separately from the 10 ms sender
  criterion; recognizability alone does not establish that accuracy.
- [ ] Supervise additional loss/network/reconnect and sleep/wake cases only when listening
  is explicitly resumed by the user. Record inaudible intervals even if the clock advances.
  No automatic playback or audible tests run while the household is sleeping.

### Gates after the prototype

- [ ] Accept the entry/return UX and its cancellation semantics, informed by handoff evidence.
- [ ] Meet the supported prevention/observability gate for unexpected local fallback, or
  obtain an explicit revised product requirement before proceeding. Document the actual
  signal/constraint and ordering, not merely an observed quiet outcome.
- [ ] Choose startup, file-size, memory and decoded-prefetch budgets; investigate incremental
  delivery only if needed. Include recovery from full disk and very long tracks.
- [ ] Design normal queue/repeat/Next/Previous and end-of-context for both backends. Evaluate
  native item continuation/`AVQueuePlayer` separately; do not promise that it inherits the
  renderer's PCM gapless behavior. Measure boundary clocks, media timing and audible gaps.
- [ ] Resolve the strict modern-transport decision/evidence rule in the feasibility plan.
- [ ] Repeated sessions, multiple receivers where available, native failure UX, reconnect,
  window/session lifetime and final integration tests pass before shipping. Mark both plans
  Done only with the implemented feature and its evidence, not at design completion.
