# The launch's connect waits for a window and two requests

Status: **Done** (2026-10-03)
Components: `Spotifly/Views/LoggedInLifecycleModifier.swift` (the window's task),
`Spotifly/ViewModels/AuthViewModel.swift` (`startSession`, `authorizeStreaming`)
Found: 2026-10-03, in the altitude review of `plans/done/the-session-is-attached-by-a-window.md`

## Summary

At a launch, this Mac connects to Spotify, and so appears on Spotify Connect, from the first
window's task, after the profile and the start page have loaded:
`await (profile, home)`, then `await playbackViewModel.initializeIfNeeded()`. After a sign-in it
connects at once, from `AuthViewModel.authorizeStreaming`. Two triggers, ordered differently.

## Problem

The connect needs neither request: it reads the keymaster grant, as they do. Waiting for both,
and for a window's first frame, delays this Mac's registration, and so a play on it, by however
long the slower of the two takes; a launch with no window (the app reopened with its window
closed) connects only when a window shows. The ordering dates from the Web API grant, whose
token the connect was handed (`initializeIfNeeded(accessToken:)`, before #49).

## Solution

As proposed: `AuthViewModel.startSession` starts `PlaybackViewModel.initializeIfNeeded()`, so a
session connects as it starts, at a launch and a sign-in alike. At a sign-in,
`authorizeStreaming`'s own awaited call, which a renewed grant needs since its session is
already started, comes first and the session's waits for it (`runInitialization`). The window's
call stays, after its requests, as the retry for a window that opens after a connect failed.

## Verification

- **A launch, before** (main): launched at 43.438, the profile and start page requests at
  43.86, the connect began at 44.847 ("Session created"), once both had answered, and completed
  at 45.228: 1.79 s after the launch.
- **After:** launched at 03.641, the connect began at 04.113, beside the two requests (04.109,
  04.119), and completed at 04.494: 0.85 s after the launch. One `Initialization complete`.
- **A faked sign-in** (throwaways, not committed): one `SpotifyPlayer.initialize`, one
  `Initialization complete`.
- 624 unit tests pass.
