# A new grant connects from the login it was meant to replace

Status: **Open**, unmeasured
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`credentialsForLogin`),
`Spotifly/SpotifyPlayer.swift` (`authorizeStreaming`), `Spotifly/Views/SpeakersView.swift`
Found: 2026-10-03, while doing `plans/done/sign-in-connects-outside-the-player-lifecycle.md`

## Summary

Speakers offers "Enable this Mac" while the player cannot connect, and says why in a comment:
"revoked or stale credentials leave the file in place while every initialization fails". But
the connect after that grant still logs in from the file. `LibrespotClient.credentialsForLogin`
takes the stored reusable login whenever there is one, and falls back to the keymaster token
only without it. Nothing clears the file except a logout (`clearStreamingCredentials`).

So if the accesspoint ever refuses the stored login while the grant stands, the way back that
Speakers offers repeats the failing login, every time, until a logout.

## Problem

Unmeasured: whether Spotify refuses a reusable login while the keymaster grant, from the same
authorization, still refreshes. A revoked app revokes both, and the revoked grant already signs
the app out (`KeymasterSession.grantRevoked`). A password change or a reset of the account's
devices might refuse only the stored login.

## Solution

Proposed: a grant the app accepts supersedes the stored login. `AuthViewModel`, after the account
check, has the client forget the reusable login (`LibrespotClient.clearStreamingCredentials()`,
which leaves the keymaster half to `SpotifyPlayer.clearStreamingCredentials()`), so the connect
logs in with the new token and stores a fresh login. A grant it rejects already clears both.
That method also bumps the client's lifecycle generation, which supersedes a connect in flight:
say whether that is wanted just before the connect that follows. The connect is
`AuthViewModel`'s `initializeIfNeeded()`, which relies on the stored login being preferred: a
rebuild of a player already up would connect from the same login. With the login forgotten it
would not, so the call needs a second look there.

Or narrower: the client drops a stored login the accesspoint refuses as bad credentials, and
tries the token at once.

## Verification

Find a refusal first: the accesspoint's answer to a stored login after Spotify's "sign out
everywhere", with the grant left in place. Without one, this stays a guard against a case that
may not arise.
