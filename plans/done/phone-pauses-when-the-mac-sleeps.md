# The phone pauses when the Mac goes to sleep

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/ViewModels/PlaybackViewModel.swift` (`setupRemoteCommandCenter`,
`observeSystemSleep`, `isSleepPause`), `SpotiflyTests/PlaybackViewModelTests.swift`
Found: 2026-10-02, live-checking `plans/done/position-behind-after-a-reconnect.md`

## Summary

While a phone played and Spotifly mirrored it, putting the Mac to sleep paused the phone. macOS
sends the now-playing app a pause as the Mac goes to sleep, Spotifly is that app while it shows
another device's playback, and `pause()` sends a pause on to the active device. A pause from the
media controls within ten seconds of the system saying it will sleep, and before it wakes, is
now dropped while another device plays.

## Problem

### Seen

From the Debug build's log, 2026-10-02, times UTC, a phone (`c077d34a…`) playing:

- **Window open:** `System will sleep, disconnecting from Spotify` at 19:05:57.357, then
  `[POST] …/connect-state/v1/player/command/from/spotifly_31860/to/c077d34a…` at 19:05:57.855.
  The phone was paused while the Mac slept.
- **Window closed:** the same `POST` at 19:07:16.848, as the Mac went to sleep, and the phone's
  report `paused=true` 120 ms later.
- Not every time: in a later run the window-open sleep sent nothing. In the first sleep test of
  the day the phone also played on.

No control in the app was pressed. Every other path to `pause()` logs something before the
command; the media command handlers logged nothing until this change. With them logging, a
window-closed sleep shows the pause arriving there:

- 19:18:34.989 `PlaybackViewModel`: `Media command: pause`, then `Pause ignored: the Mac is going
  to sleep, and another device plays`.

### Why

- **Spotifly is the now-playing app while another device plays.** It publishes that device's
  track and rate to `MPNowPlayingInfoCenter`, which is what Control Center shows.
- **macOS pauses it as the Mac goes to sleep**, through `MPRemoteCommandCenter`'s pause command.
  Why only sometimes is not known.
- **`pause()` sends the pause where playback is.** With another device active, that is a Connect
  command to it, over HTTP, which works after the session has dropped for the sleep.

## Solution

**The view model watches the system's sleep for the life of the process** (`observeSystemSleep`),
on the main queue so the mark is set before a command that follows it is handled. Not in
`LoggedInLifecycleModifier`, whose observer goes with a closed window, where the pause arrives
too.

**A pause or a play/pause that would pause is dropped** (`isSleepPause`) when:
- another device is the active one: the sleep stops nothing that plays elsewhere. This Mac's own
  playback still pauses, which the sleep's disconnect does anyway;
- the system said it will sleep less than ten seconds ago and has not woken since. Seen half a
  second after the notification. The bound keeps a sleep that never happened, and so never woke,
  from silencing the pause key for long.

**Media commands are logged** (`Media command: …`), so the next unexplained command shows where
it came from.

**Considered and not done:**
- **Not publishing another device's playback to Now Playing, or as paused.** Control Center and
  the media keys would stop showing or controlling the phone, which is the point of mirroring.
- **Dropping every system pause while another device plays.** The media keys and Control Center
  send the same command, and they should pause the phone.

## Verification

- [x] Unit tests: `SleepPauseTests`, the decision: dropped half a second after the will-sleep for
      another device, not for this Mac's own playback, and not a minute after a sleep that never
      came.
- [x] **Live** (Ralph's phone playing, a build with this and the position fix): with the window
      open, then closed, the Mac slept and woke, and the phone played on. The closed-window sleep
      logged the pause and its dropping, as quoted above.
