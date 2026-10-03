# The sign-in connects the player outside the player's lifecycle

Status: **Open**, with a proposed solution
Components: `Spotifly/SpotifyPlayer.swift` (`authorizeStreaming`),
`Spotifly/ViewModels/AuthViewModel.swift`, `Spotifly/ViewModels/PlaybackViewModel.swift`
(`runInitialization`, `performInitialization`)
Found: 2026-10-03, in the review of `plans/done/sign-in-connects-twice.md`

## Summary

Every connect of the player goes through `PlaybackViewModel.runInitialization`, which
serializes them, except one: the connect `SpotifyPlayer.authorizeStreaming` makes after a
grant. The view model then adopts that session. Two owners of the session's lifecycle.

## Problem

The post-grant connect runs in a detached task, outside the serializer, so it has none of what
`runInitialization` and `performInitialization` give every other connect:

- the lifecycle generation check, which tears down a session that outlived a logout;
- `waitUntilReady`, and the "not ready" message;
- the Premium handling;
- serialization against an `initializeIfNeeded` from a play, whose overlap
  `runInitialization`'s doc describes as the way the view model ends up holding a replaced
  session.

And it connects before `AuthViewModel` compares the grant's account with the one signed in, so a
browser signed into another account registers this Mac on Connect under that account before
the mismatch tears it down again.

## Solution

Proposed: `authorizeStreaming` ends after `KeymasterSession.adopt`, and the client, which falls
back to the keymaster token by itself, is connected by the view model:
`AuthViewModel` checks the account first, then calls `forceReinitialize()` (or a variant).

What it costs: `runInitialization` and `performInitialization` return nothing today, and
`AuthViewModel` maps the connect's outcome to `.authorized`, `.failed` or `.superseded`, so they
would need to return one. The reasons the post-grant connect is detached (`.utility`, not
cancelled with the browser wait) move with it; `runInitialization`'s unstructured task already
outlives a cancelled caller.

## Verification

None yet. No tests cover the grant path, so each outcome needs a live sign-in: a normal one, a
cancelled one, one with the browser signed into another account, and one whose connect fails.
