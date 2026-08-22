# Fix plan: waking from sleep empties the queue and leaves play dead

Ticket: `plans/wake-from-sleep-loses-queue-and-resume.md`
Status: **executed 2026-08-03.** Kept as a record of what was proposed; the ticket's
*Implemented fix* section is what actually shipped. One step below was wrong — see the
note in commit 2c — and three more came out of review.

Three independent defects, three independent commits, in this order. Each stands on its
own and is separately verifiable — deliberately not one "fix the sleep bug" change.

## Guiding principle

Both main defects are the same mistake in two places: **an absence is being read as a
fact.** An empty Web API response is read as "the queue is empty"; a false `isActiveDevice`
is read as "a remote device is playing". The fixes make the third state — *unknown* /
*nobody* — explicit, rather than adding recovery paths around the wrong conclusion.

---

## Commit 1 — a Web API bootstrap with no playback must not touch the queue

**File:** `Spotifly/Store/Services/QueueService.swift`

In `fetchInitialPlaybackState`, after the freshness barrier and before any `setQueue`, add
the "nothing to learn" early return:

```swift
// Spotify answers both requests with 204 when no device is active, and an empty queue is
// indistinguishable from one it simply cannot see. Applying it would destroy the pending
// tracks — the one part of the queue nothing else can reconstruct — while `setQueue`'s
// `previous: nil` contract preserves the history, which is exactly backwards. Absence of a
// server answer is not evidence that the queue is empty.
guard playbackState != nil || queueResponse.currentlyPlaying != nil else {
    log("Web API reports no playback anywhere — keeping the existing queue")
    return false
}
```

Return `false` (nothing applied), which is what the documented contract already means. The
one caller that reads it, `scheduleQueueRefresh`, will retry up to three times and then
stop — harmless, and correct for the provisional-`SetQueue` case it exists for.

Deliberately **not** done here:

- Reinstating the current track from `PlaybackViewModel.currentTrackUri` when the queue has
  no `currentTrack`. That invents queue contents from playback state; with commit 1 in
  place the pointer is never lost in the first place.
- Splitting `setQueue` into per-field optionals. The bug is the caller applying a response
  it should have rejected, not the store's write API.

**Test** (`SpotiflyTests/`, new file or alongside `QueueReconciliationTests.swift`): the
guard is a pure predicate over two optionals — extract it as a small
`static func webAPIHasPlayback(_:_:) -> Bool` if that makes it testable without a network
double, and assert the four combinations. The store-level behaviour ("a queue survives a
no-playback bootstrap") is worth an `AppStore` test too: set a queue with previous +
current + next, apply the no-playback path, assert the queue is unchanged.

---

## Commit 2 — route transport commands locally when *nobody* is the active device

**Files:** `Spotifly/SpotifyAPI/SpotifyAPI+Player.swift`,
`Spotifly/SpotifyAPI/APITypes.swift`, `Spotifly/ViewModels/PlaybackViewModel.swift`

### 2a. Give "there is no device to command" a type

`throwAPIError` flattens every non-2xx into `.apiError(String)`, so the caller cannot
distinguish `404 NO_ACTIVE_DEVICE` from a real failure. Add a case:

```swift
case noActiveDevice   // "No active device found" — nothing to send transport commands to
```

and in the six transport endpoints (`pausePlayback`, `resumePlayback`, `skipToNext`,
`skipToPrevious`, `seekToPosition`, `setShuffle`) add `case 404: throw .noActiveDevice`
ahead of the `default:`. Leave `throwAPIError` alone — a blanket 404 mapping would change
behaviour for endpoints where 404 means something else.

### 2b. Fall back to the local player

`PlaybackViewModel.sendTransportCommand`:

```swift
guard SpotifyPlayer.isActiveDevice else {
    Task {
        guard let token = await tokenProvider?() else { return }
        do {
            try await remote(token)
        } catch SpotifyAPIError.noActiveDevice {
            // Three cluster states, not two: we are active, someone else is, or nobody is.
            // `!isActiveDevice` does not distinguish the last two, and the Web API cannot
            // act on the third — but the local Spirc can, and `spotifly_resume` already
            // activates on its way through `resume_via_load`.
            guard SpotifyPlayer.isSessionConnected else { return }
            debugLog("PlaybackViewModel", "\(name): no active device — running locally")
            local()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    return true
}
```

This fixes the whole family at once — `resume`, `pause`, `next`, `previous`, `seek`,
`toggleShuffle` — and is self-correcting: it carries no cached cluster state that could go
stale.

### 2c. Skip the dead wait in `spotifly_resume` (optional, same commit)

> **Wrong, and the most important step of the lot.** This framed activation as a latency
> saving, and it was dropped on the reasoning that a rebuilt Player holds no track so
> `spirc.play()` would find nothing to resume either way. That premise is true and
> irrelevant. `SpircTask` matches `_ if !self.connect_state.is_active()` *ahead of* `Play`,
> `Load`, `Next`, `Prev`, `Shuffle` and `SetPosition`, so all of them are discarded while
> inactive — activation is what lets the fallback `Load` reach Spirc at all, and without it
> 2b accomplished nothing. `handle_activate` loads no context, which is exactly why the
> Player being empty says nothing about whether activation is needed. Codex caught it;
> the unit tests could not, since the behaviour lives in librespot.


`spotifly_resume` (`rust/src/lib.rs:2392`) calls `spirc.play()` first and only reaches
`resume_via_load` after `wait_for_playing_event(…, 500)` times out. On an inactive device
that 500 ms is always wasted. Calling `ensure_active_for_playback(&spirc)` at the top —
which `spotifly_play_uri` and `spotifly_play_tracks` already do — removes it. Behaviourally
optional; include it only if it stays a two-line change.

### Alternatives considered

- **Re-activate on wake.** Preserve "we were active before sleep" across
  `spotifly_disconnect` (capture the `RecoveryIntent` before `spirc.shutdown()`, stash it,
  read it in `spotifly_force_reconnect`) and pass `activate_after_connect: true`.
  *Rejected as the primary fix:* it fixes only the sleep path, and unconditional
  re-activation on wake would take the Connect role back from a phone that legitimately
  took over while the Mac slept. Guarding against that needs the cluster's active-device id
  at reconnect time, which is more machinery than 2b for a narrower fix.
- **Publish the cluster's active-device id in the connection snapshot** and route on it
  (add `active_device_id` to `ConnectionState` and `ConnectionStateInfo`, clear it in
  `do_reconnect_cleanup`, derive `remoteDeviceIsActive` in Swift). Principled and avoids
  the extra round trip, but it introduces a second piece of cluster state that has to be
  kept accurate across every rebuild — the existing `LAST_ACTIVE_DEVICE_ID` shows the trap:
  it is a notification latch, is never cleared on reconnect, and after a rebuild holds a
  stale *own* device id that would read as "a remote device is active". Not worth it for a
  failure the 404 already reports accurately.
- **Surfacing `errorMessage` in the Now Playing bar.** Worth doing on its own merits, but
  it turns a silent failure into a visible one rather than fixing it.

**Test:** the routing decision is currently inline in a closure. Extracting the
"which target" choice is overkill; cover it at the Rust boundary instead — the existing
`is_active_in_cluster` tests already assert the three-state distinction — and verify 2b at
runtime (below).

---

## Commit 3 — the queue counter must not point past the end

**Files:** `Spotifly/Store/AppStore.swift`, `Spotifly/Views/NowPlayingBarView.swift`

`currentIndex` is `previousTracks.count`, which exceeds `queueLength - 1` whenever there is
history but no current track — reachable legitimately when a queue plays out. Either clamp
in the store:

```swift
var currentIndex: Int {
    min(queue.previousTracks.count, max(0, queueLength - 1))
}
```

or, better, have `NowPlayingBarView.swift:343` render nothing when
`store.queue.currentTrack == nil`, since "track n of m" is meaningless without a current
track. Prefer the second — the store value is honest, it is the label that is wrong.
`QueueListView` uses the same `currentIndex` for its played/pending split and its
scroll-to-current, so check both read sensibly with no current track.

---

## Verification

Automated first (`SpotiflyTests`, `cargo test`), then the runtime path, which is the only
thing that proves it:

1. Play an album locally with 2+ tracks pending, Queue section open.
2. Pause. `pmset sleepnow`. Wait 2 minutes. Wake.
3. **Expect:** the log shows `Web API reports no playback anywhere — keeping the existing
   queue`, and the queue still shows the current track and the pending ones, with the
   counter matching.
4. Press Play. **Expect:** one `PUT /me/player/play`, then
   `resume(): no active device — running locally`, then
   `Resume fallback: loading context … at 93606ms`, then a `Playing` event and audio from
   where it was paused.
5. Regression on the handoff case: start playback on a phone, confirm Spotifly's transport
   buttons still drive the phone through the Web API and do **not** steal playback back.
6. Regression on cold start: launch with nothing playing anywhere and confirm the queue
   bootstrap still behaves (empty queue, no crash, no spurious retries beyond the three).

Build and lint per `plans/`-adjacent convention before each commit; `swiftformat
--swiftversion 6.3 .` on the Swift changes, `cargo clippy` against the existing baseline on
the Rust ones.

## Risks

- **Commit 1 keeps a queue that may be genuinely stale.** If the user really did stop
  everything elsewhere, Spotifly now shows the last queue it knew instead of clearing it.
  That matches what Spotify's own clients do, and a wrong-but-plausible queue is strictly
  better than a destroyed one — the pending tracks cannot be reconstructed from anywhere.
- **Commit 2 costs one failed round trip** before falling back. Only on the "nobody is
  active" path, which is rare and already the broken one.
- **Commit 2 makes Spotifly take the active role** when the user presses play with no
  device active. That is what pressing play means, and `spotifly_play_uri` already does
  exactly this today.
