# Sleep and wake are handled by the window, so a closed window skips them

Status: **Open**, not planned. The closed-window behaviour is read from the code and from one
log, not measured on purpose.
Components: `Spotifly/Views/LoggedInLifecycleModifier.swift` (the `willSleepNotification` and
`didWakeNotification` handlers), `Spotifly/ViewModels/PlaybackViewModel.swift`
(`observeSystemSleep`)
Found: 2026-10-02, in the review of `plans/done/phone-pauses-when-the-mac-sleeps.md`

## Summary

The disconnect before sleep and the reconnect after the wake are `.onReceive` handlers on
`LoggedInView`, so they go with a closed window: the session stays up into the sleep, and the
wake starts no reconnect. The client recovers on its own (a closed-window sleep on 2026-10-02
logged `Socket died: no pong within 3.0 seconds` after the wake, then `Recovery succeeded`), but
later than the window's reconnect would. `PlaybackViewModel` now watches the same two
notifications for the life of the process, for the pause at sleep, so sleep is handled in two
places that live for different lengths of time.

## Solution

Not planned. Probably one sleep/wake observer in a process-lifetime object, the view model or
the client, that disconnects, reconnects and marks the sleep for the pause, with the window's
handlers removed. That changes what a closed-window sleep does, so it needs checking live: a
phone playing and paused, and this Mac playing.

## Verification

None yet.
