# Idle Reconnect Fixes — Design Spec

**Date:** 2026-03-18
**Status:** Approved

## Problem

After pausing playback and returning to the app after a long idle period, the app enters a permanently broken state:

1. **Play button does nothing.** The Rust reconnect loop fires autonomously, may partially succeed (session authenticated) but Spirc never becomes ready. `isSessionConnected` stays `false` indefinitely. `resume()`/`pause()` are silently ignored.

2. **Manual reconnect (Speakers tab) doesn't fix it.** `forceReinitialize` reinits Rust successfully, but `PlaybackViewModel` retains stale state (`isPlaying`, `currentTrackUri`, position anchor). After reinit `isActiveDevice` is false; pressing play sends a Web API resume that fails silently because Spotify has no active paused session.

Root cause confirmed from `no-reaction-after-being-idle.log`: Rust hard reconnect attempt 4 logged "successful" at 17:01:00 but Spirc never initialized. App sat broken from 17:01 to 17:07 with no recovery path.

## Design

### Change 1 — Wake handler: use `forceReinitialize` instead of `forceReconnect`

**File:** `Spotifly/Views/LoggedInView.swift`

Replace the `didWakeNotification` handler body:

```swift
// Before
SpotifyPlayer.forceReconnect()

// After
Task {
    let token = await session.validAccessToken()
    await playbackViewModel.forceReinitialize(accessToken: token)
}
```

`forceReconnect()` triggers the same Rust reconnect loop that gets stuck. `forceReinitialize` does a full `spotifly_cleanup()` + `init_player_async()` — the only path proven to reliably recover.

### Change 2 — Reconnect watchdog in `LoggedInView`

**File:** `Spotifly/Views/LoggedInView.swift`

Add a constant and a `@State` property to track the watchdog task:

```swift
private let reconnectWatchdogTimeoutSeconds: Double = 120

@State private var reconnectWatchdogTask: Task<Void, Never>? = nil
```

Subscribe to session disconnect/connect publishers:

```swift
.onReceive(SpotifyPlayer.sessionDisconnected) {
    reconnectWatchdogTask?.cancel()
    reconnectWatchdogTask = Task {
        // try? is load-bearing: cancellation throws CancellationError which would
        // skip the guard; try? silences it so the guard can check isCancelled cleanly.
        try? await Task.sleep(for: .seconds(reconnectWatchdogTimeoutSeconds))
        guard !Task.isCancelled, !SpotifyPlayer.isSessionConnected else { return }
        debugLog("LoggedInView", "Watchdog: still disconnected after \(Int(reconnectWatchdogTimeoutSeconds))s, forcing reinit")
        let token = await session.validAccessToken()
        await playbackViewModel.forceReinitialize(accessToken: token)
    }
}
.onReceive(SpotifyPlayer.sessionConnected) {
    reconnectWatchdogTask?.cancel()
    reconnectWatchdogTask = nil
    // ... existing sessionConnected logic
}
```

The watchdog fires only if `isSessionConnected` is still false after the full timeout — meaning the Rust loop has stopped making progress. Brief network blips (< 2 min) self-recover via the Rust loop without reaching the watchdog.

### Change 3 — State reset after `forceReinitialize`

**File:** `Spotifly/ViewModels/PlaybackViewModel.swift`

At the end of `forceReinitialize`, after the Spirc ready wait loop, unconditionally reset playback state:

```swift
// Reset stale playback state — after reinit Rust has no track/context loaded.
// Call updateNowPlayingPosition() before zeroing trackDurationMs: the method
// guards on trackDurationMs > 0 and would silently no-op if called after.
updateNowPlayingPosition()  // clears playback rate in Now Playing center
isPlaying = false
currentTrackUri = nil
trackDurationMs = 0
currentPositionMs = 0
positionAnchorMs = 0
positionAnchorTime = CACurrentMediaTime()
```

This applies to all callers (wake handler, watchdog, manual reconnect button). The user sees a clean "nothing playing" state and can start fresh playback. Losing track/queue state is explicitly acceptable per requirements.

## Data Flow

```
sessionDisconnected fires
  ├─ watchdog Task starts (120s sleep)
  │
  ├─ [sessionConnected fires within 120s]
  │    → watchdog Task cancelled — no reinit
  │
  └─ [120s elapses, isSessionConnected still false]
       → forceReinitialize() called silently
       → PlaybackViewModel state reset
       → sessionConnected fires
       → QueueService.fetchInitialPlaybackState() (existing handler)

didWakeNotification fires
  → forceReinitialize() called with fresh token
  → PlaybackViewModel state reset
  → sessionConnected fires
  → QueueService.fetchInitialPlaybackState()
```

## Edge Cases

| Scenario | Behaviour |
|---|---|
| Watchdog fires while user is also clicking manual reconnect | Both call `forceReinitialize`; it's safe — sets `isLoading=true`/`isInitialized=false` upfront, second call waits on same Spirc poll |
| Brief network blip (< 2 min) | `sessionDisconnected` fires, Rust self-recovers, `sessionConnected` fires, watchdog cancelled — no reinit |
| Machine sleeps and wakes before watchdog fires | Wake handler calls `forceReinitialize` directly; `sessionConnected` fires, watchdog cancelled |
| `session` reference in watchdog | Watchdog is defined inside `.onReceive` on the view, which has `session` (a `@State`-stored `SpotifySession`) in scope — captured correctly |

## Files Changed

| File | Change |
|---|---|
| `Spotifly/Views/LoggedInView.swift` | Replace `forceReconnect()` in wake handler; add watchdog constant + state + publishers |
| `Spotifly/ViewModels/PlaybackViewModel.swift` | Add state reset block at end of `forceReinitialize` |

No Rust changes. No new files.

## Tuning

`reconnectWatchdogTimeoutSeconds` is a `private let` constant at the top of `LoggedInView` — easy to find and adjust.
