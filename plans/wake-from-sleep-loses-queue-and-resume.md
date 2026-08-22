# Waking from sleep empties the queue and leaves the play button dead

Status: **fixed and confirmed at runtime, 2026-08-03.** Kept as a record.
`dfa447f`, `0be0c8c`, `3f61731`, then `e5011b0` and two follow-ups from review; see
*Implemented fix* below. Confirmed by a manual sleep/wake cycle on the reporter's Mac:
the queue survives and the paused track resumes. The handoff regression check — another
device playing while Spotifly's transport buttons drive it remotely — was not part of that
run and remains unexercised.
Components: `Spotifly/Store/Services/QueueService.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/Store/AppStore.swift`,
`rust/src/lib.rs`
Found: 2026-08-03, branch `sleep-issue`. Evidence: `../sleep.log`, `../sleep.json`,
screenshot of the Queue section.

## Symptom

Play an album locally, pause it (AirPods into their case), let the Mac sleep, walk away.
On return, with the Queue section open the whole time:

1. The queue shows **only already-played tracks**, all dimmed, header reading
   `8 Songs (0 ausstehend)`. The tracks that were still pending are gone.
2. The **currently loaded track is missing from the queue**. The Now Playing bar still
   shows `I'm So Bored` and its paused position, but the queue no longer contains it —
   the two views disagree about what is playing.
3. The bar's queue counter reads **`9/8`**: an index past the end of the list.
4. **Play does nothing.** Pressing it repeatedly produces one Web API request each and no
   playback, no error, no state change. The paused track cannot be resumed at all.

Only quitting and relaunching, or explicitly playing something new, recovers.

## Evidence

### Timeline (`sleep.log`)

```text
09:29:00.639  PlayerEvent::Playing: spotify:track:3U6zVXn1JBiT0QiyJHUJ2o   # I'm So Bored, 286894ms
09:30:34.263  spotifly_pause called                                       # AirPods into case
09:30:34.307  PlayerEvent::Paused: … at 93606ms
09:33:48.255  System will sleep, disconnecting from Spotify
09:33:48.502  WARN couldn't load context info because: context is not available
09:33:48.537  became inactive (SessionDisconnected) …
09:33:48.537  Active device changed: is_active=false                      # ← the fact that is lost
09:33:48.637  drop Spirc[1] / Cluster listener ended without recovery
09:35:58.885  [WAKE +0ms] spotifly_force_reconnect called                 # 2m10s asleep
09:35:58.886  Connection not ready, position frozen at 93606ms
09:36:01.293  [WAKE +2408ms] Spirc ready - connected to Spotify Connect
09:36:01.498  [WAKE +2613ms] Reconnect successful on attempt 1
09:36:01.500  QueueService … Fetching initial playback state from Web API...
09:36:01.500  [GET] https://api.spotify.com/v1/me/player?market=from_token
09:36:01.500  [GET] https://api.spotify.com/v1/me/player/queue
09:36:01.697  QueueService … Initial queue: current=0, next=0             # ← the wipe
09:36:02.262  INFO active device is <> with session <…>                   # nobody is active
09:38:26.967  [PUT] https://api.spotify.com/v1/me/player/play             # ← 8 presses, 8 requests,
…  (×8, through 09:38:32.951)                                            #   zero effect
```

Two silences in that log are as informative as the lines:

- **No `Initial playback:` line follows the bootstrap.** `QueueService` only logs it when
  `playbackState != nil` (`QueueService.swift:356`), so `/me/player` returned **204 No
  Content** — Spotify had no playback state to report at all.
- **No playback-state or queue callback follows the eight `PUT`s.** The requests were
  answered with `404 NO_ACTIVE_DEVICE`; there was no device for them to command.

### Store dump (`sleep.json`, taken after the fact)

```json
"queue": {
  "previousTracks": [ …8 entries, "Raise Your Hands" … "You're Not The Only One"… ],
  "nextTracks": [],
  "isLoading": false
}
```

`currentTrack` is absent (nil). `devices` is `{}` and `activeDeviceId` is absent, so Swift
holds no device information whatsoever. `connection` reports
`isConnected: true, spircReady: true` — the session is perfectly healthy. The failure is
entirely in what Swift believes about the queue and about where to send commands.

This is the exact shape the screenshot shows: 8 previous, no current, no next, so
`currentIndex` (8) equals `queueLength` (8) and the counter renders `8 + 1` over `8`.

## Mechanism

### Defect 1 — "the Web API knows nothing" is applied as "the queue is empty"

Wake triggers a reconnect, the connection snapshot goes not-ready then ready, and
`LoggedInLifecycleModifier.swift:112-116` re-bootstraps from the Web API. Inside
`fetchInitialPlaybackState` the two responses are applied unconditionally
(`QueueService.swift:326-337`):

```swift
let currentEntry: QueueEntry? = queueResponse.currentlyPlaying.flatMap { … }   // nil
let nextEntries: [QueueEntry] = queueResponse.queue.map { … }                  // []

store.setQueue(previous: nil, current: currentEntry, next: nextEntries)
reconcileQueueCurrentTrack()
```

`fetchQueue` maps 204 to `QueueResponse(currentlyPlaying: nil, queue: [])`
(`SpotifyAPI+Player.swift:86-88`) and `fetchPlaybackState` maps 204 to `nil`
(`SpotifyAPI+Player.swift:386-388`). Both are **absence of information**, not a report
that the queue is empty — with no active device, Spotify has nothing to say about what is
queued. The code cannot tell the two apart and writes the emptiness into the store.

`AppStore.setQueue` (`AppStore.swift:678`) then does the maximally damaging thing: the
`previous: nil` contract preserves history, while `current` and `next` are assigned
unconditionally. So the one part of the queue that is genuinely unrecoverable — what is
still to play — is destroyed, and the part that is pure history is kept.

The freshness barrier does not help. `liveStateRevision` is only bumped by callbacks from
Rust (`AppStore.swift:671`), and no callback arrived during those 197 ms — precisely
because nothing was playing. The barrier defends against *newer* live state, not against
*absent* server state.

`reconcileQueueCurrentTrack()` cannot repair it either.
`PlaybackViewModel.currentTrackUri` is still `spotify:track:3U6zVXn1JBiT0QiyJHUJ2o`, but
`Queue.reconciled(currentTrackId:)` (`AppStore.swift:38-56`) can only re-split a list that
already contains the track. `I'm So Bored` was the *current* entry, so wiping `current`
removed it from the list entirely and the reconciliation returns `self` unchanged. This is
why the Now Playing bar and the queue end up disagreeing: the bar is never touched
(`applyWebAPIPlaybackState` is guarded by `if let state = playbackState`, which was nil),
so it keeps the correct track while the queue has dropped it.

### Defect 2 — `!isActiveDevice` is read as "a remote device is playing"

Every transport command routes through `sendTransportCommand`
(`PlaybackViewModel.swift:499-523`):

```swift
guard SpotifyPlayer.isActiveDevice else {
    Task { … try await remote(token) … }      // → PUT /me/player/play
    return true
}
guard SpotifyPlayer.isSessionConnected else { … }
local()                                        // → spotifly_resume
```

There are three cluster states, not two: *we* are active, *someone else* is active, or
**nobody** is active. The guard collapses the third into the second and sends the command
to a device that does not exist. Spotify answers `404`, `throwAPIError` turns it into
`SpotifyAPIError.apiError` (`SpotifyAPI.swift:29-34`), and it lands in `errorMessage`,
which nothing in the Now Playing bar displays. Hence "nothing happened", eight times.

The local path would have worked. `spotifly_resume` (`lib.rs:2392`) falls back to
`resume_via_load` (`lib.rs:2322`), which reloads the saved context at `POSITION_MS` and
calls `set_active_device(true)`. None of `CURRENT_CONTEXT_URI`, `CURRENT_TRACK_URI` or
`POSITION_MS` is cleared by `do_reconnect_cleanup` (`lib.rs:1217-1255`) — Rust still held
everything needed to resume `I'm So Bored` at 93606 ms. `spotifly_play_uri` and
`spotifly_play_tracks` already call `ensure_active_for_playback` (`lib.rs:2091`) for
exactly this reason, so *starting* a new track would have worked. Only *resuming* was
unreachable.

### Why the flag was false — the sleep teardown deactivates us

`spotifly_disconnect` (`lib.rs:2508`) calls `spirc.shutdown()`. librespot answers any
shutdown with `handle_disconnect`, which emits `PlayerEvent::SessionDisconnected`, and the
handler at `lib.rs:1601-1608` clears the active flag:

```rust
let intent = RecoveryIntent::capture();
set_active_device(false);
```

That handler is correct for its normal case — a genuine handoff to a phone or speaker —
but here Spotifly deactivated *itself* on the way into sleep, and nothing records that it
did. Two minutes later `spotifly_force_reconnect` captures the intent afresh
(`lib.rs:1209`) and reads `was_playing: false, was_active: false`, so
`init_player_async(&token, false, false)` takes the `else` branch at `lib.rs:1702` and
records `store_active_device(false)`. The rebuilt session is connected, Spirc-ready, and
deliberately not the active device — which is a defensible passive-startup policy, but it
leaves Swift permanently routing to a Web API that has no target.

### Defect 3 (minor) — the queue counter can point past the end

`NowPlayingBarView.swift:343` renders `store.currentIndex + 1` over `store.queueLength`,
where `currentIndex` is `previousTracks.count` (`AppStore.swift:261`) and `queueLength`
counts the current entry only when it exists (`AppStore.swift:257`). Any state with
history and no current track prints `n+1` of `n`. Defect 1 produced it here, but a queue
played to its end reaches the same state legitimately.

## Scope

- Defects 1 and 3 need no sleep at all: **any** reconnect that finds no active playback
  wipes the queue. Sleep is simply the reliable way to reach it.
- Defect 2 affects `resume`, `pause`, `next`, `previous`, `seek` and `toggleShuffle`
  alike — everything routed through `sendTransportCommand`. Resume is where it is fatal,
  because it is the only one with no other way in.
- The user-visible severity is high: paused playback becomes unresumable, and the queue is
  lost with no way to get it back short of relaunching.

## Implemented fix

1. **The bootstrap keeps the queue when the response carries no playback.**
   `QueueService.responseCarriesPlayback` names the distinction between "Spotify has nothing
   to say" and "nothing is queued", and `fetchInitialPlaybackState` returns early rather
   than writing the emptiness into the store.
2. **404 from the player endpoints is `SpotifyAPIError.noActiveDevice`**, and a transport
   command that hits it runs locally instead of reporting a failure nothing displays.
3. **`spotifly_resume` activates before playing.** This was the part the plan got wrong.
   It proposed the activation as an optional latency saving and reasoned it could be
   dropped, "because after a rebuild the Player holds no track, so `spirc.play()` finds
   nothing to resume whether or not the device is active". The Player is indeed empty, but
   that is not why activation matters: `SpircTask` matches
   `_ if !self.connect_state.is_active()` **ahead of every transport command**, so `Play`,
   `Load`, `Next`, `Prev`, `Shuffle` and `SetPosition` are discarded with a warning while
   inactive. Without activating, the whole local fallback — the `resume_via_load` it relies
   on included — was dropped in silence, and fix 2 alone changed nothing. Caught by Codex
   review, not by the tests.
4. **`resume_via_load` no longer claims activity for a queued load.** It called
   `set_active_device(true)` whenever `Spirc::load` returned `Ok`, which only means the
   command reached the channel. A load discarded for inactivity therefore looked like a
   successful takeover, after which Swift routed everything to a local player that was
   ignoring it. Activity is recorded where it is established, never inferred.
5. **Only one resume runs at a time.** `spotifly_resume` takes up to 2.5 s and `IS_PLAYING`
   stays false throughout, so repeated presses each queued their own play-then-load, each
   restarting the track at its own captured position. Pre-existing on the active-device
   path; the fallback just made it easy to reach.
6. **The queue counter** is rendered only while a current track exists, with the queue glyph
   and an accessibility label in the slot otherwise.

What the fallback recovers is **resume**, and that is the whole of it. With nobody active
there is no context loaded and nothing playing, so pause, next, previous, seek and shuffle
reach an inactive Spirc and are correctly dropped. Activating for them would take the
Connect role from the user's other clients to accomplish nothing, and making them work would
mean silently starting playback in response to "next" — a different feature.

## To reproduce

1. Play an album locally with several tracks still pending, Queue section open.
2. Pause.
3. Let the Mac sleep (or `pmset sleepnow`), wait past the reconnect, wake.
4. Observe `Initial queue: current=0, next=0` in the log, the queue showing only
   played tracks, and Play producing `PUT /me/player/play` with no effect.

A regression check is the log line `Initial queue: current=0, next=0` appearing while the
store still had a current track and pending tracks.

## Related

- `plans/position-interpolation-runs-on-during-outage.md` — same wake path; the freshness
  barrier and readiness ordering introduced there guard against *stale* server state, not
  against *absent* server state.
- `plans/queue-current-pointer-lags-requested-index.md` — the reconciliation that cannot
  help here because the track is no longer in the list.
