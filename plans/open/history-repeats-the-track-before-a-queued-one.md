# The history repeats the track played before a queued one

Status: **Open.** Recorded, not planned. Shown in a unit-test probe; not observed in the app.
Components: `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`advance`, `pushHistory`,
`backward`)
Found: 2026-09-29, while writing `plans/done/queue-double-click-restarts-the-context.md`

## Summary

When a track queued by hand ends and the context carries on, `advance` records the context
track from *before* the queued one in the history a second time. Previous then goes back to
that track twice, and the queue view lists it twice. Which queued tracks the history keeps
depends on what followed them.

## Problem

A probe on `PlaybackQueue`, context `t0 t1 t2`, 2026-09-29:

| Played | `history` |
|---|---|
| t0, then queued q0, then t1 | `[t0, t0]` |
| Previous twice from there | t0, then t0 again |
| From t0, queued q1 and q2, then on | `[t0, q1, t0]`, current t1 |

`advance` pushes the current track before it moves:

- **Into a queued track.** It pushes `currentUri`, which is the queued track playing, or the
  context track when none is. So a queued track followed by another is recorded, and the last
  one of a run is not.
- **Back into the context.** It clears `userQueueCurrent` first, then pushes. `currentUri` is
  then the context track at `currentIndex`, the one pushed already when the queued track
  started, so it goes in twice.

## Solution

Not planned yet. First decide what the history should hold:

- **Like librespot.** Its `next_track` puts only context and autoplay tracks in
  `prev_tracks`: "only add songs from our context to our previous tracks". Here that means
  never pushing a queued track, and not pushing on the way back into the context, since that
  track is already there.
- **Or everything played.** Push the queued track as it ends, so Previous can go back to it.

Either way, `backward()` has to agree: it assumes the entry before a queued track names the
context track to return to. `plans/done/queue-history-listed-newest-first.md` (#81) orders the
same list.

## Verification

Not defined yet. A unit test on `PlaybackQueue` with the three rows above.
