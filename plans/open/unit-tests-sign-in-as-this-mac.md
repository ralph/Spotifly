# Unit tests sign in as this Mac

Status: **Open**, not planned. Inferred from the code and one observation; not confirmed.
Components: `Spotifly/SpotiflyApp.swift`, `Spotifly/Views/ContentView.swift`,
`Spotifly/Views/LoggedInLifecycleModifier.swift`, `Spotifly/SwiftLibrespot/Core/DeviceInfo.swift`
Found: 2026-09-29, while probing the Connect registration for #58 from the test host

## Summary

`SpotiflyTests` runs inside the app (`TEST_HOST` is `Spotifly.app`), and nothing in the app
checks for a test run. So each test run most likely launches a second, signed-in Spotifly that
logs in and registers on Spotify Connect under the **same device id** as the Debug app the
developer has open. When the run ends, the host is killed and that registration goes with it.

## Problem

- **Why it would sign in.** The host shares the app's bundle id and sandbox container, so it
  finds the same keymaster grant (`AuthViewModel.init` sets `isSignedIn` from
  `KeymasterSession.shared.hasGrant`), the same stored login (`credentials.json`) and the same
  `SpotifyDeviceId` in defaults. `LoggedInLifecycleModifier` then calls
  `initializeIfNeeded()`, which logs in and registers.
- **What was seen.** Two probe tests for #58 each registered a throwaway device, seconds
  apart, and listed the cluster. In the first, a device with a `spotifly_` id other than the
  probe was listed; in the second, none was, although the developer's Debug app was running
  throughout. That fits the host registering and dropping the shared id. It does not prove
  it: the first listing could have been the host itself.
- **What it would cost.** For up to a heartbeat (30 s) after each test run, the developer's
  running app may be missing from other devices' lists, or stand for a process that has gone.
  Tests also make network requests nobody asked for.

## Solution

Not planned. The likely shape: detect the test host at launch (for example
`XCTestConfigurationFilePath` in the environment, or a launch argument from the scheme) and
show an empty scene without signing in. Confirm the problem first.

## Verification

Not planned. To confirm the problem: with the Debug app open, watch its device in the web
player's device list, or log `SpircController` in a run of the host (`TEST_RUNNER_` prefixed
variables reach it), while running the unit tests.
