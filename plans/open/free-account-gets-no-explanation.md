# A free account gets no explanation

Status: **Open**, priority 2. Planned, not started (#58, branch `plan/free-account-exit`).
Decided 2026-09-29: a free account browses, without local playback.
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
this Mac plays no audio for it. Controlling another device already runs on the grant, and this
plan leaves it as it is.

### Task 1: read the account type

- [ ] **Capture the real payload first.** Add a `debugLog` of the `ProductInfo` payload,
      run once, and keep the XML as the test fixture. Do not write one from librespot's
      parser. An invented fixture only certifies the guess.
- [ ] Parse `type` from it in `Accesspoint.handlePacket`, next to `countryCode`, which is
      handled the same way. Keep it on the session. Foundation's `XMLParser` is enough for a
      flat list of elements.
- [ ] Expose it to the app through `LibrespotConnectionState` as one field, for example
      `accountType: String?`, nil until the packet arrives. The UI decides what counts as
      premium, not the client.

### Task 2: make a refused login terminal

- [ ] If the accesspoint does refuse with `premiumAccountRequired`, set the same state as
      `type != premium`. Do not leave it to the recovery path: `.failed` arms
      `startAutoRecoveryIfNeeded`, which would reconnect against a refusal that will never
      change. Check whether an initial-login failure can reach that path before adding any
      guard for it. If it cannot, write that down and add nothing.

### Task 3: browse-only

- [ ] **Turn off local playback, not the library.** When `accountType` is not premium, a
      play aimed at this Mac says why, instead of failing with a raw error. That covers a
      double-click on a track, Play on an album or playlist, and the bar's transport controls
      while no other device is active. It is one check where `PlaybackViewModel` routes a
      play to the local player. It is not a guard in every view.
- [ ] **Tell the user once, and offer Logout.** A notice, not a screen that replaces the app,
      because the library still works. It says local playback needs Premium and offers
      Logout for switching accounts. `PremiumRequiredView` was deleted in `ff87034` because
      nothing could reach it, so bring back only what this needs, once Task 1 can reach it.
- [ ] **Do not offer this Mac as a speaker.** A phone that sees Spotifly in its device list
      will transfer playback to it, and the transfer will fail. First check whether the
      device list and the remote commands depend on the Connect registration
      (`SpircController.registerDevice`). If they do not, skip the registration for a free
      account. If they do, register in a way that refuses transfers, and write down which.
- [ ] New localization keys go in `de`, `en` and `fr`.

### Not in this plan

- **A subscription that lapses mid-session.** librespot handled attribute pushes over Spirc.
  The Swift stack reads `ProductInfo` at login only, so the change shows on the next launch.
  That is a known, bounded gap, and closing it is not worth a dealer subscription.

## Verification

Nobody here has a free account, so the checks that matter need none:

- [ ] A unit test that parses the captured `ProductInfo` fixture, plus a copy of it edited to
      `free`.
- [ ] Live, Debug build: `SPOTIFLY_DEBUG_ACCOUNT_TYPE=free` overrides the parsed value. Launch
      with it: the library loads, a play on this Mac shows the notice instead of an error,
      Logout works, and a phone does not list this Mac as a speaker. Without it, nothing
      changes. Paste the `Accesspoint` line that shows the parsed type.
- [ ] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare with the exit
      code checked.
- [ ] If a free account can be borrowed, run the real case and record what happens,
      including whether login succeeds. That settles the question this plan can only reason
      about.
