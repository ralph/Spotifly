# Sleep and wake are handled by the window, so a closed window skips them

Status: **Done** 2026-10-02. The closed-window path is verified with sleep and wake notifications
posted inside the app; real sleeps are pending, see Verification.
Components: `Spotifly/ViewModels/PlaybackViewModel.swift` (`observeSystemSleep`,
`systemWillSleep`, `systemDidWake`), `Spotifly/Views/LoggedInLifecycleModifier.swift` (the
handlers removed), `Spotifly/SpotiflyApp.swift` (`hostsUnitTests`)
Found: 2026-10-02, in the review of `plans/done/phone-pauses-when-the-mac-sleeps.md`

## Summary

The disconnect before sleep and the reconnect after the wake were `.onReceive` handlers on
`LoggedInView`, so they went with a closed window: the session stayed up into the sleep, and the
wake started no reconnect. The client recovered on its own (a closed-window sleep on 2026-10-02
logged `Socket died: no pong within 3.0 seconds` after the wake, then `Recovery succeeded`), but
later than the window's reconnect would. `PlaybackViewModel` already watched the same two
notifications for the life of the process, for the pause at sleep, so sleep was handled in two
places that lived for different lengths of time.

Both handlers now live in `PlaybackViewModel`, next to the sleep mark, and the window's are gone.

## Problem

`LoggedInLifecycleModifier` is applied to `LoggedInView`, which exists while a window shows the
logged-in app. Closing the window keeps the process running, along with `PlaybackViewModel.shared`
and the librespot session, but drops the view and its `.onReceive` subscriptions. So with the
window closed:

- **Before the sleep**, nothing disconnected. The Mac stayed listed as a Connect device on other
  devices until Spotify noticed it gone.
- **After the wake**, nothing asked for a reconnect. The session found out from its own
  keep-alive, seconds later.

## Solution

`observeSystemSleep` (in `init`, so for the life of the process) now calls:

- `systemWillSleep()`: sets the sleep mark for `pauseFromMediaControls`, then
  `SpotifyPlayer.disconnect()`. The mark comes first, so a pause that macOS sends right after it
  is already recognised.
- `systemDidWake()`: clears the mark, then `SpotifyPlayer.forceReconnect()`. With no session to
  reconnect, it rebuilds with `forceReinitialize()`, as the window did.

The window only existed while signed in, so its rebuild never ran after a logout. The view model
outlives a logout, so `systemDidWake` first asks `KeymasterSession.shared.hasGrant`, which is what
being signed in means (`AuthViewModel.isSignedIn` is read from it, and that view model lives in the
window). Signed out, it logs and does nothing.

The unit-test host shows no window, but a test can still create `PlaybackViewModel.shared`:
`QueueHydrationTests` does, through `QueueService.hydrate()`. The host has the developer's grant,
so a wake during a test run would have signed it in as the developer's Debug device. The code
review found this. `observeSystemSleep` now returns early under `SpotiflyApp.hostsUnitTests`, the
flag that already keeps the window out of the host.

## Verification

### Closed window, sleep and wake posted inside the app (2026-10-02)

A throwaway hook, not committed, posted `NSWorkspace.willSleepNotification` and, 20 s later,
`didWakeNotification` on the workspace notification center. The silent librespot test device
played an album, Spotifly mirrored it, and the window was closed with ⌘W before the sleep. Both
logs say `windows: 0 visible` at each post.

- **Before (main, `efa398d`):** nothing after either post. No disconnect, no reconnect.
- **After:**
  - At the sleep: `System will sleep, disconnecting from Spotify`, `Disconnect requested`, the
    pipeline stopped, `PutState spircNotify active=false`, the dealer and accesspoint
    disconnected.
  - At the wake: `System wake detected, reconnect under way`, the accesspoint connected 231 ms
    later, and `Recovery succeeded` 536 ms after the wake.
  - The test device played on throughout: Spotifly mirrored it playing, on its next track, at the
    reconnect.

A posted notification brings no real sleep, so macOS's pause at sleep and a real network outage
are not part of this check.

Not checked: the wake's signed-out branch. Reaching it needs a logout, and logging in again is
the user's.

### Real sleeps, window closed

Pending: a phone playing, a phone paused, and this Mac playing.

### Seen in passing

The disconnect's last PutState is answered with the cluster, and its position is not extrapolated
while the connection is down: the bar went from 168616 ms back to 141119 ms ("timestamp was
27540ms ago") for the 20 s of the posted sleep. The same happens with the window open, as before
this change. In a real sleep the screen is off by then, and the wake's reconnect re-anchors the bar
within a second, so it was left as is.
