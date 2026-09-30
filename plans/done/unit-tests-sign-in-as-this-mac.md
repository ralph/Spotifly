# Unit tests sign in as this Mac

Status: **Done** 2026-09-29 (#88). Confirmed with a probe test, fixed, and the fix seen by the
same probe; see Verification.
Components: `Spotifly/SpotiflyApp.swift`, `DEVELOPMENT.md`
Found: 2026-09-29, while probing the Connect registration for #58 from the test host

## Summary

`SpotiflyTests` runs inside the app (`TEST_HOST` is `Spotifly.app`), and nothing in the app
checked for a test run. So each test run launched a second, signed-in Spotifly that logged in
and registered on Spotify Connect under the **same device id** as the Debug app the developer
has open. The app now opens an empty window when it hosts the tests, and does not sign in.

## Problem

- **Why it signed in.** The host shares the app's bundle id and sandbox container, so it
  finds the same keymaster grant (`AuthViewModel.init` sets `isSignedIn` from
  `KeymasterSession.shared.hasGrant`), the same stored login (`credentials.json`) and the same
  `SpotifyDeviceId` in defaults. `LoggedInLifecycleModifier` then calls
  `initializeIfNeeded()`, which logs in and registers.
- **What was seen first.** Two probe tests for #58 each registered a throwaway device, seconds
  apart, and listed the cluster. In the first, a device with a `spotifly_` id other than the
  probe was listed; in the second, none was, although the developer's Debug app was running
  throughout. That fitted the host registering and dropping the shared id, without proving it.
- **Confirmed.** A probe test polled `PlayerModel.shared.connection` from inside the host
  (2026-09-29, the developer's app not running). 1.5 s into the run it read
  `grant=true connected as device spotifly_31860 named Spotifly`: the Debug app's own device
  id. The host's stderr, where `debugLog` writes, reaches neither `xcodebuild`'s output nor the
  result bundle, which is why no test run had shown it.
- **What it cost.** Each run logged in to the accesspoint, registered, and fetched the cluster,
  as the developer's app. While that app was open, the two shared one Connect identity, and
  when the host was killed the device could go missing from other devices' lists, or stand
  for a process that had gone, until the next heartbeat.
- **It can log the developer out.** Signing in, the host refreshes the grant when its access
  token is near expiry, and keymaster refresh tokens rotate: Spotify keeps one live refresh
  token per client id and account (`KeymasterSession.supersedeRefresh`). The host is killed at
  the end of every run. Killed after Spotify rotated the token and before the keychain got the
  new one, it leaves a dead refresh token behind, and the next refresh, by the app or the next
  host, gets `invalid_grant`, and `KeymasterSession` forgets the grant. Seen 2026-09-29: the
  grant read `true` from a test host at about 19:05; after a dozen full test runs on branches
  without this fix, it read `false` from two different builds at 19:50, and a Debug launch
  showed the login screen. Inferred from that and the code, not caught in the act.

## Solution

`SpotiflyApp` checks `XCTestConfigurationFilePath`, which Xcode sets in the host's environment
for both XCTest and Swift Testing runs (the probe read it as set). Hosting the tests, the
`WindowGroup` shows an `EmptyView` in place of `ContentView`, so no `AuthViewModel` is created,
nothing reads the grant at launch, and `LoggedInView` never appears to initialize the player.
The tests still load the app's code as before; none of them relied on the host being signed in.

The UI tests are unaffected: `XCUIApplication` launches the app as its own process, without
that variable.

## Verification

- [x] The probe, before: `grant=true connected as device spotifly_31860 named Spotifly`,
      1.5 s into the run.
- [x] The probe, after: `grant=true never connected`, polling for 20 s. The grant is still
      readable, so the test host can reach it; it just no longer signs in with it. The probe
      was a temporary test file, deleted again.
- [x] Build, 441 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live, by the developer: with the Debug app open and playing, run the unit tests. The app keeps
      playing, and the phone's device list keeps showing Spotifly throughout and after. Not run on
      2026-09-30: the tests ran only while the app was quit.
- [x] Live, 2026-09-30: every Debug build launched that day signed in and played.
