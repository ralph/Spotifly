# A sign-in connected the player twice

Status: **Done** 2026-10-03, verified with a logout and sign-in by the user
Components: `Spotifly/SpotifyPlayer.swift`, `Spotifly/ViewModels/AuthViewModel.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-10-03, in the log of the user's logout and sign-in for #177

## Summary

After a sign-in, the player connected to Spotify, and 140 ms later tore that session down and
connected again. The grant's own connect had already brought it up, and `AuthViewModel` then
forced a rebuild, from a time when the grant's connect was not a working session.

## Problem

From the log of a sign-in (2026-10-03, 04:35):

- 09.774 the token exchange; 09.902 a session is created; 10.170 "Initialization complete".
  This is `SpotifyPlayer.authorizeStreaming`'s post-grant connect.
- 10.170 `PlaybackViewModel`: "Adopting recovery the client completed on its own". The view
  model took that session as its own.
- 10.306 "Shutting down", a new session, and 10.567 "Initialization complete" again. This is
  `AuthViewModel` calling `forceReinitialize()` after `isSignedIn = true`.

Its comment said the grant only wrote credentials to disk. That was once so, and later the
post-grant connect was a session without the client token, which could fetch nothing; the
comment on `connectClient` said it "survived only because the grant path immediately rebuilds
through `initialize`". Since the two connects share `connectClient`, the rebuild only cost a
second accesspoint login, dealer socket and Connect registration, and a moment in which this
Mac left Connect and came back.

The one thing the rebuild still did: `initialize()` applies the saved output volume before
connecting (`syncSettingsFromUserDefaults`), and the post-grant connect did not.

## Solution

- The post-grant connect goes through `SpotifyPlayer.initialize()`, so it applies the saved
  volume as every other connect does. `connectClient` folded into it.
- `AuthViewModel` calls `initializeIfNeeded()` instead of `forceReinitialize()`.
- `initializeIfNeeded()` first adopts a client that is already up (`handleConnectionChange`,
  renamed `adoptConnectedSession`, whose log line no longer calls every adoption a recovery),
  since the snapshot that says so can still be on its way to the view model when the sign-in
  resumes. Without that, it would see an uninitialized model and rebuild all the same.

### Left as it was

The sign-in still connects outside `PlaybackViewModel.runInitialization`, as before: without
its generation check, readiness wait or Premium handling, and before the account mismatch is
checked. `plans/open/sign-in-connects-outside-the-player-lifecycle.md`.

## Verification

The user logged out and signed in again with this build, then played (2026-10-03, 04:39):

- 23.813 the token exchange; 23.926 one session created; 24.196 "Initialization complete" and
  "Adopting recovery the client completed on its own". No teardown followed.
- 30.179 playback started, on a fresh store (`store:707`, then `store:369`).
- 617 unit tests pass.
