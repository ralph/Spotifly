# The sign-in connects the player outside the player's lifecycle

Status: **Done** (2026-10-03); a real sign-in for each outcome is left to the PR's manual test
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

`SpotifyPlayer.authorizeStreaming` ends after `KeymasterSession.adopt`. `AuthViewModel` checks
the account, signs in, and connects through `PlaybackViewModel.initializeIfNeeded()`. The app
shows during the connect, so its profile and start page load meanwhile (the review's
suggestion; before, the login screen waited for the connect), and the window's own
`initializeIfNeeded` waits for this one rather than starting another. A logout during the
connect is the player's to undo (`performInitialization`'s generation check), and nothing is
written after it. The `.superseded` outcome went with the detached connect that produced it.

`initializeIfNeeded` no longer adopts a connected session first: that was added for the
sign-in's own connect (`plans/done/sign-in-connects-twice.md`), which is gone. A recovery is
still adopted by the connection observer.

What the plan expected it to cost did not arise:
- **No outcome to return.** `AuthViewModel` mapped a failed connect to `auth.connect_failed`,
  but it set `isSignedIn` too, so the login screen that shows that message was gone. The
  player's own `errorMessage` says a failed connect in the now-playing bar, as for any other.
- **`initializeIfNeeded`, not `forceReinitialize`.** A grant is offered only while this Mac
  cannot play, so the player is down; if a play brought it up from the stored login while the
  browser had the grant, a rebuild would connect from that same login again (the client
  prefers it to the token), taking this Mac off Connect for nothing. Its Premium guard cannot
  bite either: the teardown resets `streams`.
- **The detachment.** The connect runs in `runInitialization`'s unstructured task, which a
  cancelled caller does not cancel, as the detached task did not.

## Verification

No tests cover the grant path, which needs the browser. Faked live, with throwaways that showed
the login screen while the keychain kept its grant and answered the grant after 2 s without a
browser (not committed):

- **A sign-in:** "Connect with Spotify" pressed by accessibility. Signed in when the grant
  answered, then one `SpotifyPlayer.initialize`; the window's startup `initializeIfNeeded` came
  while it ran, and waited for it. One `Initialization complete`, this Mac ready, no adoption.
- **A sign-in whose connect fails** (a throwaway threw from the first `initialize`): signed in,
  this Mac not ready; the window's startup call, a second later, connected once.
- Both again with the login screen waiting for the connect (the order before the review): the
  same, one connect each.
- 617 unit tests pass.

Left for a real sign-in: a normal one, a cancelled one, and a re-authorization from Speakers
with the browser signed into another account (which signs the app out, by design).
