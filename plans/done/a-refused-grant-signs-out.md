# A grant for another account signs the app out

Status: **Done** (2026-10-03), verified with a second account
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

Mint, check, then commit, as proposed:
- `AuthViewModel.authorizeStreaming` runs `KeymasterAuth.authorize()` itself, which writes
  nothing, then checks the logout, and adopts. A refused or abandoned grant needs no undoing;
  a logout that lands while the tokens are written is undone by a second check, which clears
  the keymaster tokens (`KeymasterSession.clear()`).
- **The account is checked in `KeymasterSession.adopt`**, against the grant it holds, in the
  same step as the write: tokens for another account throw `otherAccount`, and holding none is
  a sign-in. From the review: the first version compared with the profile's account
  (`store.userId`), which is nil until the profile loads, and nil counted as agreement, so
  another account got through right after a failed launch, when "Enable this Mac" is most
  likely to show. `accountMismatch` and the callers' `expectedAccountId` are gone.
- A refusal keeps the app signed in. `errorMessage` was shown only on the login screen, so the
  signed-in app shows it as an alert ("This Mac was not enabled"), on the window so the mini
  player shows it too, and it waits for OK: the grant finishes in the browser, where a passing
  message in the now-playing bar would be missed, and it can start from Speakers or from the
  play alert. A failed token exchange while signed in is said there too; before, its message
  went nowhere. `logout()` clears it.
- `SpotifyPlayer.authorizeStreaming`, `StreamingAuthResult` and `lastGrantAccountId()` are
  gone: the grant no longer touches the player. `discardGrant` had one caller left and is part
  of `logout()`.

## Verification

With a second Spotify account in the browser, by the developer (2026-10-03). A throwaway
failed the first connect after launch, so Speakers offered "Enable this Mac" while signed in.

- **Refused:** the token exchange at 06:24:50.813, `Streaming grant rejected` 110 ms later,
  and nothing after it: no shutdown, no registration. The alert said why; after OK the app was
  still signed in, its library there, and Speakers still offered the row.
- **Accepted**, the browser back on the signed-in account: the token exchange at
  06:25:14.758, the device registered, `Initialization complete` at 06:25:15.261, and playing
  worked.
- **Again with the check in `adopt`** (06:34): refused 105 ms after the other account's token
  exchange, nothing after it; accepted with the signed-in account, `Initialization complete`
  at 06:34:25.306.
- Before (2026-10-03, #186's test): the refusal signed the app out.
- Unit tests for `adopt`: another account is refused and the held grant stays, unwritten; the
  same account replaces it; with none held, any account signs in. 622 tests pass.
