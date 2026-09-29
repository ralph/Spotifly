# A free account gets no explanation

Status: **Open**, priority 2. The plan is on #58, branch `plan/free-account-exit`. Decided
2026-09-29: a free account browses, without local playback.
Components: `Spotifly/SwiftLibrespot/Network/Accesspoint.swift` (`handlePacket`),
`Spotifly/SpotifyPlayer.swift` (`LibrespotConnectionState`),
`Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-08-13, reading librespot's `check_catalogue`. Re-read against the Swift stack on
2026-09-29.

## Summary

Spotifly has no handling for an account without Premium. Under librespot the app quit,
because `check_catalogue` called `exit(1)`. The Swift stack has no exit, but it drops the
packet that carries the account type, so a free account most likely logs in and then fails at
every play, with a raw error in the bar. Nobody here has a free account, so none of this has
been observed.

## Problem

### What the Swift stack does

- **The account type arrives, and is dropped.** After login the accesspoint sends a
  `ProductInfo` packet (0x50), an XML list of attributes whose `type` is `premium` or `free`.
  `Accesspoint.handlePacket` has no case for it. The packet reaches `default:` and logs
  `Unhandled packet type: productInfo`, as it does in `../transfer.log` (2026-08-25).
- **Login most likely succeeds.** `SpotifyErrorCode.premiumAccountRequired` (11) exists, and
  an accesspoint refusal would surface as `authenticationFailed("premiumAccountRequired: …")`.
  But librespot needed `check_catalogue` precisely because free accounts got through login.
- **So the failure, if there is one, lands at playback.** It would come at the audio key, the
  CDN, or the extended-metadata request, where `SPClient` sends `catalogue = "premium"`.
  Since #72 each failed play shows its error in the bar, so a free account would see raw
  errors on every play and no explanation.

Everything that is not streaming runs on the keymaster grant and does not depend on the
product type: library, search, playlists, and driving another Connect device.

### Found under librespot

librespot ended the process for any account whose type was not `premium`, in
`check_catalogue`, reached at sign-in and from two mid-session attribute pushes. That is why
`PremiumRequiredView` was deleted in `ff87034`: nothing could ever reach it.

## Solution

Decided 2026-09-29: browse-only. A free account keeps the library, search and playlists, and
this Mac plays no audio for it. The plan on #58 reads the account type, keeps a refused login
out of the recovery loop, turns off local playback and the Connect speaker, and shows a notice
with Logout.

## Verification

Defined with the plan on #58. None of it needs a free account: a debug override sets the type.
