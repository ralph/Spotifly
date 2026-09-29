# A free account gets no explanation

Status: **Done** 2026-09-29 (#58). Not seen with a free account: nobody here has one, so a
free account's login and packet are still inferred, and the live checks run on a Premium
account under `SPOTIFLY_DEBUG_ACCOUNT_TYPE=free`.
Decided 2026-09-29: a free account browses, without local playback.
Components: `Spotifly/SwiftLibrespot/Network/Accesspoint.swift` (`handlePacket`, `refusal`),
`Spotifly/SwiftLibrespot/Core/LibrespotSession.swift` (`connect`),
`Spotifly/SwiftLibrespot/Connect/SpircController.swift` (`buildDevice`),
`Spotifly/SpotifyPlayer.swift` (`LibrespotConnectionState`),
`Spotifly/ViewModels/PlaybackViewModel.swift` (`playbackTarget`, `sendTransportCommand`),
`Spotifly/Views/LoggedInView.swift`, `Spotifly/Views/SpeakersView.swift`
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
`PremiumRequiredView` was deleted in `f09b996` (#51): nothing could ever reach it.

## Solution

Decided 2026-09-29: browse-only. A free account keeps the library, search and playlists, and
this Mac plays no audio for it. Controlling another device already runs on the grant, and this
plan leaves it as it is.

### Task 1: read the account type

- [x] **Capture the real payload first.** Captured 2026-09-29 by a throwaway accesspoint
      login from the test host, with the stored login and a device id of its own, so the
      running app was not touched. It is 4,759 bytes:
      `<?xml version='1.0' encoding='utf-8'?><products><product>`, then 101 flat elements,
      `<type>premium</type>` first and the rest in alphabetical order. `catalogue` and
      `player-license` are `premium` too. A family plan's member is `type` `premium`, with
      `multiuserplan-member-type` beside it. The fixture,
      `SpotiflyTests/Fixtures/product-info-premium.xml`, keeps the declaration, nesting and
      order and 8 of the elements. The rest describe the plan and its billing
      (`financial-product` names the plan and its price), or are client flags.
- [x] Parsed in `Accesspoint.handlePacket`, next to `countryCode`, as `accountType`. A regex
      for `<type>…</type>` rather than `XMLParser`: the elements are flat, the value is a
      word, and nothing else is read.
- [x] **Changed from the plan: the app gets a Bool, not the type.** The session needs the
      decision before it registers (Task 3), so it makes it once, as
      `LibrespotSession.streams`, by librespot's rule (`streams(accountType:)`): only
      `premium` streams, and a type that never came is let through. The client publishes
      that as `LibrespotConnectionState.streams`, and the UI reads it as
      `SpotifyConnection.streams`. Carrying the type as well meant working the rule out
      twice, once in the session and once in the app, for a value nothing else reads. The
      type itself is in the `Accesspoint` log line.

### Task 2: make a refused login terminal

- [x] A refusal with `premiumAccountRequired` throws `LibrespotError.premiumRequired`, from
      both places a login is refused: the unencrypted `APResponseMessage`, and the
      `AuthFailure` packet, whose `APLoginFailed` was dropped until now (the error only said
      "Server rejected authentication"). The client publishes it as it publishes a free
      account's type, `streams` false, at the first login or a recovery. So a play aimed
      here explains Premium instead of asking to authorize, and `initializeIfNeeded` does not
      log in again at every play.
- [x] **An initial-login failure cannot reach the recovery path**, so nothing guards it there.
      `Flags.beginRecovery` answers `.noSession` unless `hasEverConnected` and `hasSession`
      are both set, and both are set only after `initialize` succeeds; `teardown` clears
      `hasSession` before each one. A refusal at a *recovery* would retry, but that needs the
      subscription to lapse mid-session, which is out of scope below.

### Task 3: browse-only

- [x] **Local playback is off, the library is not.** `PlaybackViewModel.localPlayback` is
      one value, `.ready`, `.needsAuthorization` or `.needsPremium`, and `playbackTarget`
      sends a play here only when it is `.ready`. Otherwise the play goes to the active
      device, if there is one, and is explained if not. Where a Premium account's play goes
      is unchanged: this Mac, even while a phone plays. Radio routes through the same
      function with no remote option. The transport controls' fallback when no device is
      active, which would take over the track another device left, checks the same value,
      and queueing with nothing active adds nothing here either. Behind all of it,
      `LibrespotClient.loadAndPlay`, which every local start passes, refuses with
      `premiumRequired`, so a path the view model misses shows the reason, not a raw error.
- [x] **Told once, with Logout.** The first play this Mac refuses raises an alert that says
      the library, search and playlists work and playing here needs Premium, with Logout and
      OK. Once per launch, and again after a logout. Every refused play also says it in the
      bar, as "Playing on this Mac needs Spotify Premium.", since the mini player shows the
      bar and not the alert. Speakers says it in place of "Enable this Mac".
      Nothing of `PremiumRequiredView` came back.
- [x] **This Mac is not offered as a speaker.** The device list does depend on the
      registration: the cluster is the answer to a PutState and the dealer pushes it to
      registered devices, so skipping the registration would lose the device list and the
      playback shown from another device. So a free account registers **the way the web
      player does when it cannot play**: its observer device sends
      `capabilities: {can_be_player: false, hidden: true, needs_full_player_state: true}`
      (`_register`, `vendor~web-player.4ad2b3e0.js`, 2026-09-29). Here `can_play` and
      `can_be_player` are false and `hidden` is true. Measured with a throwaway device the
      same day: registered hidden, it got the cluster back and the cluster did not list it;
      registered as today, it listed it. Commands this Mac sends name it only in the url,
      which the backend does not check (see `connectRoute`).
- [x] New keys in `de`, `en` and `fr`: `playback.needs_premium`, its `_title` and `_message`,
      `speakers.this_mac_needs_premium` and `common.ok`.

### Not in this plan

- **A subscription that lapses mid-session.** librespot handled attribute pushes over Spirc.
  The Swift stack reads `ProductInfo` at login only, so the change shows on the next launch.
  That is a known, bounded gap, and closing it is not worth a dealer subscription.

## Verification

Nobody here has a free account, so the checks that matter need none:

- [x] Unit tests (`AccountTypeTests`): the captured fixture reads `premium`, a copy edited to
      `free` reads `free`, and one without `type` reads none. Only `premium` streams, and a
      missing type does. A device that may not play builds a registration with `can_play`
      and `can_be_player` false and `hidden` true. `PlaybackTargetTests` covers the routing:
      a play goes here for Premium even with a phone active, to the phone for a free account,
      and to `.needsPremium` with nothing active.
- [x] The hidden registration, live, with a throwaway device id from the test host
      (2026-09-29): hidden, the cluster came back with 2 devices, the app's own among them
      and the probe not; registered as a player, the probe was listed.
- [x] Live, Debug build of `63ae6de` (this branch with main merged), DE Premium account,
      2026-09-29. All eight of #58's checks **passed**:
      - With `SPOTIFLY_DEBUG_ACCOUNT_TYPE=free` the log reads
        `[2026-09-29T18:53:56.950Z DEBUG Accesspoint] Account type: premium`, then
        `Account type run as free`.
      - The library, a playlist, an album and a search load.
      - The phone does not list this Mac. Speakers says "Dieser Mac spielt nur für
        Premium-Konten", with no row to enable it.
      - With nothing playing, the first double-click raises the notice and the bar
        message, and the next one only the bar message. Play on an album, Start Radio and the
        bar's Play show the bar message. The log shows the bar's Play refused: `resume() had
        no active device, and this account does not stream here`.
      - The mini player's Play shows the bar message.
      - With the phone playing, a double-click plays on the phone. Pause and Next control
        it, and the bar and the queue follow it. The Mac never reported itself active.
      - Logout in the notice returns to the login screen.
      - Without the variable, the log shows only `Account type: premium`. The phone lists
        Spotifly, and a double-click plays on the Mac.
- [x] Build, 387 unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare, exit 0.
      Again after merging main: 441 tests, lint exit 0.
- [ ] If a free account can be borrowed, run the real case and record what happens,
      including whether login succeeds. That settles the question this plan can only reason
      about. Not done: none was at hand.
