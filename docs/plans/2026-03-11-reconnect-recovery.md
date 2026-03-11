# Reconnect Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent mid-playlist stops after disconnects during preload and make manual reconnect always return the app to a usable state, even if exact playback continuity is sacrificed.

**Architecture:** Keep the existing soft reconnect path for ordinary disconnects, but track reconnect rehydration explicitly and escalate to a hard rebuild when queue/context state does not repopulate. Make manual reconnect a deterministic hard reset that clears stale Rust and Swift state, then rehydrates from cluster callbacks first and Web API only as fallback.

**Tech Stack:** Rust (`librespot`, Tokio), Swift/SwiftUI, `Testing`, Xcode test target, Cargo unit tests

---

### Task 1: Add Rust recovery-state reset helper and failing tests

**Files:**
- Modify: `rust/src/lib.rs`
- Create: `rust/src/reconnect_recovery_tests.rs`
- Test: `rust/src/reconnect_recovery_tests.rs`

**Step 1: Write the failing test**

```rust
#[test]
fn cleanup_clears_cached_recovery_state() {
    seed_recovery_state_for_test(RecoveryStateSeed {
        current_track_uri: Some("spotify:track:abc".into()),
        current_context_uri: Some("spotify:playlist:def".into()),
        duration_ms: 123_000,
        position_ms: 45_000,
        resume_after_reconnect_until_ms: 999_999,
    });

    clear_runtime_state_for_test();

    let snapshot = recovery_snapshot_for_test();
    assert_eq!(snapshot.current_track_uri, None);
    assert_eq!(snapshot.current_context_uri, None);
    assert_eq!(snapshot.duration_ms, 0);
    assert_eq!(snapshot.position_ms, 0);
    assert_eq!(snapshot.resume_after_reconnect_until_ms, 0);
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path rust/Cargo.toml cleanup_clears_cached_recovery_state -- --exact`

Expected: FAIL because the helper/test seam does not exist yet and `spotifly_cleanup()` still leaves cached context/track state behind.

**Step 3: Write minimal implementation**

```rust
fn clear_recovery_caches() {
    CURRENT_DURATION_MS.store(0, Ordering::SeqCst);
    POSITION_MS.store(0, Ordering::SeqCst);
    POSITION_TIMESTAMP_MS.store(0, Ordering::SeqCst);
    RESUME_AFTER_RECONNECT_UNTIL_MS.store(0, Ordering::SeqCst);

    *CURRENT_TRACK_URI.lock().unwrap() = None;
    *CURRENT_CONTEXT_URI.lock().unwrap() = None;
    clear_pending_play();
}
```

Call this helper from:

- `spotifly_cleanup()`
- `do_reconnect_cleanup()`

Do not clear the reconnect seed from `do_soft_reconnect_cleanup()`; that state is needed for soft-to-hard fallback decisions.

**Step 4: Run test to verify it passes**

Run: `cargo test --manifest-path rust/Cargo.toml cleanup_clears_cached_recovery_state -- --exact`

Expected: PASS

**Step 5: Commit**

```bash
git add rust/src/lib.rs rust/src/reconnect_recovery_tests.rs
git commit -m "test: cover reconnect cleanup state"
```

### Task 2: Add soft-reconnect rehydration watchdog and hard-fallback tests

**Files:**
- Modify: `rust/src/lib.rs`
- Modify: `rust/src/reconnect_recovery_tests.rs`
- Test: `rust/src/reconnect_recovery_tests.rs`

**Step 1: Write the failing test**

```rust
#[test]
fn soft_reconnect_without_context_rehydration_requires_hard_fallback() {
    let seed = RecoverySeed {
        was_active: true,
        was_playing: true,
        current_track_uri: Some("spotify:track:abc".into()),
        current_context_uri: Some("spotify:playlist:def".into()),
        had_next_tracks: true,
    };

    let signals = RecoverySignals {
        got_fresh_context_for_epoch: false,
        got_fresh_queue_for_epoch: false,
        timed_out_waiting_for_rehydration: true,
        manual_reconnect_requested: false,
    };

    assert_eq!(
        recovery_action_after_soft_reconnect(&seed, &signals),
        RecoveryAction::HardReconnectAndReloadSeed
    );
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --manifest-path rust/Cargo.toml soft_reconnect_without_context_rehydration_requires_hard_fallback -- --exact`

Expected: FAIL because the recovery action helper and reconnect watchdog state do not exist yet.

**Step 3: Write minimal implementation**

```rust
enum RecoveryAction {
    KeepSoftReconnect,
    HardReconnectAndReloadSeed,
}

fn recovery_action_after_soft_reconnect(
    seed: &RecoverySeed,
    signals: &RecoverySignals,
) -> RecoveryAction {
    if seed.was_active
        && seed.was_playing
        && seed.had_next_tracks
        && seed.current_context_uri.is_some()
        && signals.timed_out_waiting_for_rehydration
        && !signals.got_fresh_context_for_epoch
    {
        return RecoveryAction::HardReconnectAndReloadSeed;
    }

    RecoveryAction::KeepSoftReconnect
}
```

Then wire it into the reconnect loop:

1. Capture a `RecoverySeed` on `SessionDisconnected`.
2. Increment a reconnect recovery epoch on every reconnect attempt.
3. Mark the epoch rehydrated when `SetQueue` or cluster `player_state.context_uri` arrives for the new generation.
4. After soft reconnect succeeds, start a short watchdog.
5. If the watchdog returns `HardReconnectAndReloadSeed`, run:
   - `do_reconnect_cleanup()`
   - `init_player_async(...)`
   - reload from saved context with `LoadRequest::from_context_uri(...)`

Use the saved track URI as `playing_track` when available and saved position as an approximate seek target. Reliability matters more than seamlessness here.

**Step 4: Run test to verify it passes**

Run: `cargo test --manifest-path rust/Cargo.toml soft_reconnect_without_context_rehydration_requires_hard_fallback -- --exact`

Expected: PASS

**Step 5: Commit**

```bash
git add rust/src/lib.rs rust/src/reconnect_recovery_tests.rs
git commit -m "feat: add reconnect rehydration fallback"
```

### Task 3: Reset Swift playback state before manual reinitialize and wait for explicit rehydration

**Files:**
- Modify: `Spotifly/ViewModels/PlaybackViewModel.swift`
- Modify: `Spotifly/Views/SpeakersView.swift`
- Create: `SpotiflyTests/PlaybackViewModelReconnectTests.swift`
- Test: `SpotiflyTests/PlaybackViewModelReconnectTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import Spotifly

struct PlaybackViewModelReconnectTests {
    @Test func forceReinitializeClearsStaleResumeState() async throws {
        let vm = PlaybackViewModel()
        vm.currentTrackUri = "spotify:track:stale"
        vm.isPlaying = false
        vm.trackDurationMs = 123_000
        vm.currentPositionMs = 45_000

        vm.prepareForReconnectRecovery()

        #expect(vm.currentTrackUri == nil)
        #expect(vm.isPlaying == false)
        #expect(vm.trackDurationMs == 0)
        #expect(vm.currentPositionMs == 0)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project /Users/ralph/code/spotifly/repos/Spotifly.xcodeproj \
  -scheme Spotifly \
  -only-testing:SpotiflyTests/PlaybackViewModelReconnectTests \
  test
```

Expected: FAIL because `prepareForReconnectRecovery()` does not exist.

**Step 3: Write minimal implementation**

```swift
func prepareForReconnectRecovery() {
    isPlaying = false
    currentTrackUri = nil
    trackDurationMs = 0
    positionAnchorMs = 0
    currentPositionMs = 0
    errorMessage = nil
}
```

Then:

- call `prepareForReconnectRecovery()` at the start of `forceReinitialize(accessToken:)`
- keep the existing hard `cleanup + init_player` path
- in `SpeakersView`, make the reconnect action perform an explicit recovery pass after reinit:
  - fetch a fresh token
  - reinitialize
  - wait for `SpotifyPlayer.isSpircReady`
  - refresh devices
  - rely on session-connected / cluster updates to rehydrate playback state

If rehydration does not produce a current track, leave the view model idle instead of forcing `resume`.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command as Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add Spotifly/ViewModels/PlaybackViewModel.swift Spotifly/Views/SpeakersView.swift SpotiflyTests/PlaybackViewModelReconnectTests.swift
git commit -m "feat: harden manual reconnect state reset"
```

### Task 4: Stop QueueService from clobbering good reconnect state with empty Web API snapshots

**Files:**
- Modify: `Spotifly/Store/Services/QueueService.swift`
- Create: `SpotiflyTests/QueueServiceReconnectTests.swift`
- Test: `SpotiflyTests/QueueServiceReconnectTests.swift`

**Step 1: Write the failing test**

```swift
import Testing
@testable import Spotifly

struct QueueServiceReconnectTests {
    @Test func emptyReconnectSnapshotDoesNotClearExistingQueue() async throws {
        let store = AppStore()
        store.setQueue(
            previous: nil,
            current: QueueEntry(trackId: "current", provider: .context),
            next: [QueueEntry(trackId: "next", provider: .context)]
        )

        let service = QueueService(
            store: store,
            tokenProvider: { "token" },
            api: .init(
                fetchPlaybackState: { _ in nil },
                fetchQueue: { _ in QueueResponse(currentlyPlaying: nil, queue: []) }
            )
        )

        await service.fetchInitialPlaybackState(
            accessToken: "token",
            recoveryMode: .reconnecting
        )

        #expect(store.currentTrackEntity != nil)
        #expect(store.nextTrackEntities.count == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project /Users/ralph/code/spotifly/repos/Spotifly.xcodeproj \
  -scheme Spotifly \
  -only-testing:SpotiflyTests/QueueServiceReconnectTests \
  test
```

Expected: FAIL because `QueueService` has no injectable API dependency or reconnect mode and currently replaces the queue with the empty snapshot.

**Step 3: Write minimal implementation**

```swift
enum PlaybackSyncMode {
    case startup
    case reconnecting
}

struct QueueServiceAPI {
    var fetchPlaybackState: @Sendable (String) async throws -> PlaybackStateResponse?
    var fetchQueue: @Sendable (String) async throws -> QueueResponse
}
```

Use this injectable API in `QueueService`. In reconnect mode:

- if Web API returns an empty queue and no current playback item
- and the store already has non-empty queue state or a newer local callback has populated `currentTrackUri`
- skip the destructive `store.setQueue(previous:nil, current:nil, next:[])`

Still allow metadata fetches and non-empty playback updates to apply normally.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command as Step 2.

Expected: PASS

**Step 5: Commit**

```bash
git add Spotifly/Store/Services/QueueService.swift SpotiflyTests/QueueServiceReconnectTests.swift
git commit -m "feat: ignore empty reconnect snapshots from web api"
```

### Task 5: Final verification and reconnect smoke coverage

**Files:**
- Modify: `docs/plans/2026-03-11-reconnect-recovery-design.md`
- Modify: `docs/plans/2026-03-11-reconnect-recovery.md`

**Step 1: Run Rust tests**

Run: `cargo test --manifest-path rust/Cargo.toml`

Expected: PASS

**Step 2: Run Swift unit tests**

Run:

```bash
xcodebuild -project /Users/ralph/code/spotifly/repos/Spotifly.xcodeproj \
  -scheme Spotifly \
  test
```

Expected: PASS

**Step 3: Manual smoke test**

1. Launch Spotifly.
2. Start a playlist locally.
3. Force a reconnect while a track is mid-playback and again near a track boundary.
4. Confirm either:
   - playback continues and the next track advances, or
   - reconnect falls back to a clean idle or rehydrated state and a fresh play works.
5. Use the Speakers reconnect button after a forced disconnect.

Expected: no permanent "stuck paused / cannot restart" state.

**Step 4: Update docs with results**

Record the exact verification commands and any residual risks in both plan docs.

**Step 5: Commit**

```bash
git add docs/plans/2026-03-11-reconnect-recovery-design.md docs/plans/2026-03-11-reconnect-recovery.md
git commit -m "docs: record reconnect recovery verification"
```

## Verification Results

Executed on March 11, 2026 in `/Users/ralph/code/spotifly/repos`.

- `cargo test --manifest-path rust/Cargo.toml`
  Result: PASS (`cleanup_clears_cached_recovery_state`, `soft_reconnect_without_context_rehydration_requires_hard_fallback`)
- `xcodebuild -project /Users/ralph/code/spotifly/repos/Spotifly.xcodeproj -scheme Spotifly -destination platform=macOS -only-testing:SpotiflyTests/PlaybackViewModelReconnectTests -only-testing:SpotiflyTests/QueueServiceReconnectTests build-for-testing`
  Result: PASS
- `xcodebuild -project /Users/ralph/code/spotifly/repos/Spotifly.xcodeproj -scheme Spotifly -destination platform=macOS -only-testing:SpotiflyTests/PlaybackViewModelReconnectTests -only-testing:SpotiflyTests/QueueServiceReconnectTests test-without-building`
  Result: PASS
- `xcodebuild -project /Users/ralph/code/spotifly/repos/Spotifly.xcodeproj -scheme Spotifly -destination platform=macOS test`
  Result: PASS

## Residual Risks

- Manual smoke coverage against a real Spotify AP disconnect during preload was not run in this terminal session.
- Verification uncovered and fixed an additional reconnect-adjacent bug: the initial `QueueService` subscription was clearing existing queue state on the `CurrentValueSubject(nil)` seed value before reconnect fallback logic could run.
- Local changes exist in `Spotifly.xcodeproj/project.pbxproj` to make the Swift test targets self-contained. Per user request, those project-file changes are being left for manual selection rather than committed automatically.
- If the `Spotifly.xcodeproj/project.pbxproj` edits are not selected, use command-line overrides equivalent to:
  `GENERATE_INFOPLIST_FILE=YES SWIFT_INCLUDE_PATHS='$(PROJECT_DIR)/build/rust/include' LIBRARY_SEARCH_PATHS='$(PROJECT_DIR)/build/rust/lib'`
