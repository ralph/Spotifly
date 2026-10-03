# A grant for another account signs the app out

Status: **Open**, with a proposed solution
Components: `Spotifly/SpotifyPlayer.swift` (`authorizeStreaming`),
`Spotifly/ViewModels/AuthViewModel.swift` (`authorizeStreaming`, `discardGrant`),
`Spotifly/Auth/KeymasterSession.swift` (`adopt`), `Spotifly/Views/SpeakersView.swift`
Found: 2026-10-03, in the review of `plans/done/sign-in-connects-outside-the-player-lifecycle.md`

## Summary

Signed in as A, "Enable this Mac" in Speakers (or the play alert) runs a grant in the browser.
If the browser is signed into B, the app refuses the grant, and signs out: A's grant, still
valid, is gone, and the login screen says why. The refusal only has to sign out because the
grant is written before it is checked.

## Problem

`SpotifyPlayer.authorizeStreaming` mints the tokens and adopts them into `KeymasterSession`,
which saves them to the keychain, replacing A's. `AuthViewModel` then reads the account back
(`SpotifyPlayer.lastGrantAccountId()`, from the keychain), and on a mismatch can only clear
everything (`discardGrant`). Adopting first was there so the tokens survived a failed connect,
and the grant no longer connects.

Two `discardGrant` calls, the logout race and the mismatch, exist to undo that write. Between
the adopt and the check, a play could connect with B's token, when there is no reusable login.

## Solution

Proposed: mint, check, then commit.
- The grant returns `KeymasterTokens` without adopting them; `AuthViewModel` compares
  `tokens.username` with the expected account and checks `authLifecycle`, and only then adopts.
  A refused or abandoned grant writes nothing, so it needs no undoing.
- The refusal keeps A signed in, so its message needs a place in the signed-in app: Speakers,
  beside "Enable this Mac", which shows `AuthViewModel.errorMessage` nowhere today.
- The grant, which no longer touches the player, can move from `SpotifyPlayer` to
  `KeymasterAuth`, with `StreamingAuthResult`.

## Verification

Needs a second Spotify account in the browser: a re-authorization from Speakers that is refused,
with the app still signed in as before and still playing afterwards.
