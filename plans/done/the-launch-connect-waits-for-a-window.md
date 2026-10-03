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

`AuthViewModel.startSession` starts `PlaybackViewModel.initializeIfNeeded()`, so a session
connects as it starts, at a launch and a sign-in alike.

From the review, one caller per path: `runInitialization` builds again for a caller that waited
on a connect that failed, so a second caller doubles every failure.
- `authorizeStreaming` connects only a renewed grant's session, which `startSession` leaves
  alone, and awaits it, for the Speakers row or play alert whose progress lasts until then. A
  sign-in's connect is the session's.
- The window's task no longer connects after its two loads: as a retry it tried at once after a
  failure, offline too, and never again. The window asks again when the network returns, as it
  does for the start page and the profile (`retryingWhenNetworkReturns`), while this Mac cannot
  play.
- A caller that waited on a connect Spotify refused for want of Premium does not try again;
  Reconnect in Speakers, which forces, still does.

## Verification

- **A launch, before** (main): launched at 43.438, the profile and start page requests at
  43.86, the connect began at 44.847 ("Session created"), once both had answered, and completed
  at 45.228: 1.79 s after the launch.
- **After:** launched at 03.641, the connect began at 04.113, beside the two requests (04.109,
  04.119), and completed at 04.494: 0.85 s after the launch. One `Initialization complete`.
- **On the final code**, with throwaways (not committed) that logged each
  `SpotifyPlayer.initialize`, failed the first, took the network away and back
  (`NetworkMonitor.update`), faked the grant with the held one, and opened Speakers:
  - a launch: one connect, done 0.38 s after it began;
  - a launch whose connect failed: no second attempt for the 11 s until the network came back,
    then one, which connected;
  - a sign-in (`renewing=false`): one connect, the session's;
  - a renewed grant from Speakers' "Enable this Mac" after a failed connect (`renewing=true`):
    one connect, the grant's, and the row was gone.
- 624 unit tests pass.
