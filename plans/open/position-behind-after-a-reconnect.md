# After sleep, another device's position shows behind by the time the Mac slept

Status: **Open**, fixed on branch `position-after-reconnect`. The build and the lint pass;
the unit test is built but not yet run, and the live checks (sleep and wake with a phone
playing, with the window open and closed, and paused) are pending. Present on main, likely since
#71 (2026-09-28), which made the player model pass on only what changed: until then the
reconnect's cluster push re-sent the unchanged state and re-anchored the bar by chance, as
`withdraw`'s comment records for a failed command. That is read from the code, not reproduced on
a build from before #71.
Components: `Spotifly/ViewModels/PlaybackViewModel.swift` (`positionClockNow`, and the
position anchor's times: `anchorPosition`, `restartPositionClock`, `interpolatedPositionMs`,
`positionAnchor(forPosition:takenAt:)`, `checkDriftAndSync`),
`SpotiflyTests/PlaybackViewModelTests.swift`
Found: 2026-10-02, putting the Mac to sleep while a phone played

## Summary

A phone played, and the Mac mirrored it in the now-playing bar. After the Mac slept for about
45 s and woke, the bar's position was behind the phone by about the time asleep, and stayed
behind until the phone sent something new: a skip, a pause, a seek or the next track. The
anchor the bar interpolates from runs on a clock that stops during sleep, and the reconnect
brings no report that would re-anchor it. The fix runs the anchor on a clock that counts sleep,
so the bar runs on across the sleep as the phone did.

## Problem

### Seen

From the Debug build's log, abridged, times UTC:

- 18:27:12.380 `PlaybackViewModel`: a playback state update at `position=2572ms` for
  `spotify:track:1CoZwAZBOWgaQjAVT96HjV`; `Position anchor: 0 -> 2572 (timestamp was 25117ms ago)`
- 18:27:14.159 `LoggedInLifecycle`: `System will sleep, disconnecting from Spotify`
- 18:27:58.477 `LoggedInLifecycle`: `System wake detected, reconnect under way`
- 18:27:59.028 `Accesspoint`: `Connected and authenticated`
- 18:27:59.442 `LibrespotClient`: `Mirroring spotify:track:1CoZwAZBOWgaQjAVT96HjV (playing=true,
  paused=false) from c077d34a…`, then `Recovery succeeded`

No `Playback state update` follows the wake.

### Why

1. **The bar interpolates from an anchor on `CACurrentMediaTime`.** `interpolatedPositionMs`
   adds the time since `positionAnchorTime` to `positionAnchorMs` while `positionRuns`.
   `CACurrentMediaTime` is `mach_absolute_time`, which does not advance while the Mac sleeps.
2. **The session drops for sleep, and the position is pinned.** `LoggedInLifecycleModifier`
   disconnects on `willSleepNotification`. With another device active,
   `syncConnectionReadiness` anchors the display where it was (`anchorPosition(frozenPosition)`)
   and `positionRuns` is false until the session is back.
3. **On reconnect it runs on from the pin.** The time since the pin, by that clock, is the time
   the Mac was awake and disconnected, not the time asleep. After a network drop while awake
   that is the whole gap, and the bar catches up on its own; after sleep, the time asleep is
   lost. So the freeze is not the fault; the clock is, and the freeze is only where the
   reconnect shows.
4. **Nothing re-anchors it.** The rebuilt session's cluster carries the phone's state
   unchanged, the same position and the same `timestamp`, so `mirror` publishes an equal
   `PlaybackState`, `PlayerModel.apply` writes nothing (`snapshot.playback == playback`), and
   `handlePlaybackStateUpdate` never runs. The reconnect re-sync in `LoggedInLifecycleModifier`
   (`fetchInitialPlaybackState`) copies only the queue.

`positionAnchor(forPosition:takenAt:)` measures a report's age in wall-clock time (`Date()`
against the report's `timestampMs`), which counts sleep, and subtracts it from a time on
`CACurrentMediaTime`, which does not. The anchor mixed two clocks that agree only while the Mac
is awake.

## Solution

**Every time the position anchor reads, stores or compares is on a clock that counts sleep.**
`positionClockNow()` reads `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, which on Darwin is the
wall-clock time since boot, to the microsecond. Measured on the development Mac on 2026-10-02,
3.5 days after boot: equal to `Date()` less `kern.boottime` to within a microsecond, where
`CACurrentMediaTime` was 25,833 s behind, the time slept since boot. It replaces
`CACurrentMediaTime` at every place the anchor used it:

- the anchor's time: `anchorPosition`'s default, and the time of the initial anchor;
- the optimistic mark, `optimisticAnchorTime`, and the grace it is judged against in
  `checkDriftAndSync`;
- `restartPositionClock`, for resume;
- the interpolation, `interpolatedPositionMs`;
- the back-dating, `positionAnchor(forPosition:takenAt:)`.

Nothing else compares with these times: `withdraw` compares two optimistic marks with each
other, and outside the view model only the interpolated position is read. `QuartzCore` was
imported for `CACurrentMediaTime` alone, and goes.

What it does in each case:

- **Another device playing, the session dropped for sleep:** the freeze pins the position at
  the drop as before. When the session comes back, the position runs on from the pin by the
  time since, the sleep included. That is the number re-applying the unchanged report would
  give: the report's position plus the wall-clock time since its timestamp. Whatever the phone
  actually did while the Mac slept, a pause, a seek, another track, is a changed report, which
  the player model passes on.
- **The window closed:** nothing disconnects for sleep, since the sleep disconnect is
  `LoggedInLifecycleModifier`, a view modifier on the window. The anchor runs on across the
  sleep, on a clock that now counts it. If the session drops after the wake, the freeze pins a
  position that already includes the sleep.
- **Another device paused:** `positionRuns` is false, and the bar shows the paused position;
  there is nothing for the clock to carry.
- **This Mac the active device:** `LibrespotClient.disconnect()` publishes the local track as
  paused before sleep, so no local anchor runs across a sleep, on either clock. With the window
  closed, nothing pauses it first: the anchor then runs on across the sleep while the pipeline
  did not, and the drift check pulls the display back to the pipeline at its next tick, within
  a second, as for any stall. The optimistic grace is judged only while this Mac plays as the
  active device, and a mark from before a sleep has outlived it, as it should. Read from the
  code, not checked live.

The unit test, `PositionClockTests`, checks the position clock against `Date()` less
`kern.boottime`: that it has run with the wall clock since boot, so it counted every sleep since.
No test can put the Mac to sleep, and on a Mac that has not slept since boot, the test cannot
tell a clock that stops in sleep from one that does not. On one that has, such a clock fails it
by the time slept.

**Considered and not done:**
- **Re-anchoring from the last report when the session comes back**, the branch's first version:
  `syncConnectionReadiness` called `handlePlaybackStateUpdate(player.playback)` when the session
  came back with another device active, so the report's wall-clock age was applied again. It
  lost to the clock:
  - It covers only a readiness flip that is observed. With the window closed, nothing
    disconnects for sleep, and a session that survives a short sleep never flips readiness, so
    the anchor ran across the sleep on a clock that did not count it.
  - `SpotifyPlayer.disconnect()` does not wait for its Task, so the drop can race the sleep,
    and with it the flip the re-anchor waited for.
  - It gives nothing the clock does not: the frozen position plus the time on a clock that
    counts sleep is the report's position plus the wall-clock time since the report, the same
    number, and what the phone did meanwhile arrives as a changed report anyway.

  Re-anchoring in `LoggedInLifecycleModifier`'s reconnect re-sync instead has the same faults,
  and does not run with the window closed either.
- **`ContinuousClock`, or `mach_continuous_time` (`CLOCK_MONOTONIC_RAW`).** These count sleep
  too, but run on the hardware clock, uncorrected, while the report ages they are combined with
  are wall-clock time: 12 s apart after the same 3.5 days. Over a 45 s sleep that is a
  few milliseconds, harmless, but `CLOCK_MONOTONIC` is the wall clock and agrees with the ages
  exactly, which also gives the unit test something exact to check.

## Verification

- [x] Build (`build-for-testing`, the tests included) and the lint.
- [ ] Unit test (`PositionClockTests`): not run yet, since running it launches the app as the
      test host and another Spotifly was running for a live test.
- [ ] **Live, as found:** a phone playing, the Mac asleep for 30–60 s, then woken. The bar
      should match the phone.
- [ ] The same with the window closed during the sleep, then reopened: the bar should match the
      phone.
- [ ] The same with the phone paused: the bar stays at the paused position.
