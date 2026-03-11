# Reconnect Recovery Design

Status: Proposed
Date: 2026-03-11

## Problem Summary

`stop-mid-playlist.log` shows a specific failure mode:

1. Playback is healthy and the playlist queue still has future tracks.
2. The Spotify AP/session drops while librespot is preparing the next track.
3. Spotifly soft-reconnects successfully, but the new Spirc instance never regains valid context/queue state.
4. The failed preload is treated as an unavailable track, the queue collapses, and playback stops at the next boundary.
5. A later manual reconnect appears to succeed, but stale Rust and Swift state can still route the next user action through `resume` against dead context instead of issuing a fresh play.

This produces two user-visible bugs:

- mid-playlist playback stops after a network/session blip
- manual reconnect can leave the app in a "connected but still broken" state

## Goals

- Prevent a disconnect during preload from permanently killing playlist advancement.
- Make manual reconnect deterministic and reliable, even if exact track/position continuity is sacrificed.
- Rehydrate queue/playback state from fresh Spotify Connect data first.
- Prevent stale or empty Web API reconnect snapshots from overwriting richer local state.

## Non-Goals

- Perfectly seamless, gapless recovery across every reconnect.
- Exact track-position preservation for manual reconnect.
- Building a second, app-owned queue model that tries to outsmart Spotify Connect.

## Approaches Considered

### 1. Soft reconnect only

Keep the current player alive, add more retries, and avoid hard teardown.

Pros:
- Best chance of uninterrupted audio.
- Smallest surface-area change.

Cons:
- This is already the path that fails in the observed log.
- It leaves too much stale state alive when Spirc reconnects without valid context.
- It does not give manual reconnect a reliable "known good" reset path.

### 2. Hard reconnect only

Always tear everything down and rebuild `Session`, `Spirc`, `Player`, and `Mixer`.

Pros:
- Simple mental model.
- Strongest guarantee that poisoned state does not survive.

Cons:
- Needlessly interrupts audio on every transient session drop.
- Throws away the useful part of the existing soft reconnect implementation.

### 3. Hybrid reconnect with authoritative hard-reset manual recovery

Keep soft reconnect for ordinary disconnects, but treat it as provisional until queue/context state rehydrates. If rehydration does not happen in time, escalate to a hard rebuild. Manual reconnect always uses the hard-reset path.

Pros:
- Preserves the fast path for ordinary network blips.
- Gives the app a deterministic fallback when context is lost.
- Matches the user's preference: reliability over exact track/position continuity.

Cons:
- Slightly more state-tracking logic.
- Needs explicit reconnect/rehydration guards in both Rust and Swift.

This is the recommended design.

## Recommended Design

### Recovery invariants

- A hard reset must clear all reconnect-sensitive state in Rust and Swift.
- Fresh cluster/Spirc state is the authoritative source of truth after reconnect.
- Web API snapshots are fallback data, not authority during reconnect recovery.
- Manual reconnect must prefer "clean idle" over "stale resume."

### Rust recovery model

Unexpected disconnects continue to enter the existing reconnect loop, but the loop gains explicit recovery state:

- capture a `RecoverySeed` on disconnect:
  - `was_active`
  - `was_playing`
  - saved `CURRENT_CONTEXT_URI`
  - saved `CURRENT_TRACK_URI`
  - saved `POSITION_MS`
  - whether the queue had future tracks
- increment a reconnect recovery epoch for every reconnect attempt
- mark the epoch as rehydrated when the new generation receives:
  - `SetQueue` with non-empty context, or
  - cluster `player_state.context_uri`, or
  - equivalent evidence that the queue/context has been repopulated

Soft reconnect remains the first automatic recovery step, but it is now provisional. After soft reconnect succeeds, Spotifly starts a short watchdog:

- if reconnect rehydrates context/queue for the current epoch, keep the soft reconnect
- if the watchdog expires while the old seed said there should still be context/next tracks, escalate to hard rebuild

The hard rebuild path must:

1. run full cleanup
2. create a fresh `Session`, `Player`, and `Spirc`
3. if the saved seed still has a valid context URI, reload via `LoadRequest::from_context_uri(...)` using the saved track hint and approximate position
4. otherwise reconnect idle

This intentionally values "playable again" over uninterrupted audio.

### Rust cleanup rules

`spotifly_cleanup()` and the hard reconnect cleanup path must clear more than connection objects. They also need to clear cached recovery state:

- `CURRENT_TRACK_URI`
- `CURRENT_CONTEXT_URI`
- `CURRENT_DURATION_MS`
- `POSITION_MS`
- `POSITION_TIMESTAMP_MS`
- `RESUME_AFTER_RECONNECT_UNTIL_MS`
- pending play state
- any reconnect epoch / recovery seed bookkeeping

Soft reconnect cleanup should not clear the cached seed that is needed to decide whether hard fallback is required.

### Swift manual reconnect model

Manual reconnect should be treated as an authoritative hard reset path.

Before reinitializing, Swift should clear local optimistic playback state so the next user action is not routed through stale `resume` logic:

- `currentTrackUri = nil`
- `isPlaying = false`
- duration / position anchors reset
- transient errors cleared

Then the reconnect flow should:

1. request a fresh token
2. call the existing `cleanup + init_player` path
3. wait for `Spirc` readiness / session connected
4. explicitly refresh device and playback state
5. allow cluster callbacks to repopulate UI state

If no playback state arrives, the app should remain connected but idle. That forces the next button press to become a fresh play request instead of an invalid resume attempt.

### State rehydration priority

After reconnect, Spotifly should trust data sources in this order:

1. cluster / Spirc callbacks
2. locally cached reconnect seed, but only to rebuild state
3. Web API, only as fallback

This matters because the reconnect log already shows `/me/player` and `/me/player/queue` returning an empty snapshot while the local player was still active. During reconnect recovery, an empty Web API snapshot must not clear a non-empty queue or current track that came from local callbacks.

### Queue/Web API policy

`QueueService.fetchInitialPlaybackState(...)` should accept a reconnect-aware mode. In reconnect mode:

- if Web API returns `current=nil`, `next=[]`, and no playback item
- and the store already has a non-empty queue or a fresh local playback update
- then do not replace the existing queue with the empty Web API snapshot

Web API remains useful for metadata fill-in, but not for clearing queue state during recovery.

### Manual reconnect success criteria

Manual reconnect is successful if either of these is true:

- playback/queue state is rehydrated from cluster or fallback API data
- the app is connected and idle, with stale playback state cleared

It is not acceptable for manual reconnect to leave the app in a state where:

- the connection UI says "connected"
- but the next play action still tries to resume a dead track/context

### Logging and observability

Add reconnect logs around:

- recovery seed capture
- reconnect epoch creation
- epoch rehydration success
- watchdog timeout
- hard fallback trigger
- manual reconnect reset / rehydration completion

These logs are necessary because the bug is timing-sensitive and spans transport, Spirc, and UI state.

## Testing Strategy

### Rust

- unit-test cleanup/reset helpers
- unit-test recovery action decisions from pure helper functions
- unit-test that reconnect with missing rehydration escalates to hard fallback

### Swift

- test that manual reconnect clears stale playback state before reinit
- test that reconnect-mode queue sync ignores empty Web API snapshots when richer local state exists

### Manual verification

- reproduce a reconnect while a playlist is mid-playback
- reproduce a reconnect near a track boundary
- use the Speakers reconnect button after forcing a broken/disconnected state
- confirm that the app either continues playback or returns to a clean, usable idle state

## Verification Results

Verification completed on March 11, 2026:

- Rust unit tests passed via `cargo test --manifest-path rust/Cargo.toml`
- focused Swift reconnect tests passed via `build-for-testing` plus `test-without-building`
- full `xcodebuild -project /Users/ralph/code/spotifly/repos/Spotifly.xcodeproj -scheme Spotifly -destination platform=macOS test` passed in the current working tree

During verification, one additional reconnect-adjacent defect surfaced and was fixed: `QueueService` was clearing existing queue state when its `CurrentValueSubject` emitted the initial `nil` seed value. That behavior would have undercut reconnect preservation even when the Web API fallback policy was correct.

Manual smoke verification against a live Spotify disconnect during preload was not executed in this session, so the remaining risk is in timing against real network/AP behavior rather than in the covered state-machine logic.

Note: local test-target configuration changes in `Spotifly.xcodeproj/project.pbxproj` were used for Swift test verification but are being left uncommitted for manual selection. If those edits are omitted, equivalent `xcodebuild` verification needs explicit overrides for generated test Info.plists and Rust include/library search paths.

## Expected Outcome

After these changes:

- a session drop during preload should no longer strand the player at the next track boundary
- manual reconnect should always leave the app usable again
- stale reconnect state should no longer survive cleanup
