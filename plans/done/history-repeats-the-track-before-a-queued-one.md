# The history repeats the track played before a queued one

Status: **Done** 2026-09-29. Built and unit-tested; not yet seen in the running app; see
Verification.
Components: `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`advance`, `pushHistory`,
`backward`), `plans/open/queue-rows-have-no-identity.md`
Found: 2026-09-29, while writing `plans/done/queue-double-click-restarts-the-context.md`

## Summary

When a track queued by hand ended and the context carried on, `advance` recorded the context
track from *before* the queued one in the history a second time. Previous then went back to
that track twice, and the queue view listed it twice. Which queued tracks the history kept
depended on what followed them. The history now holds context tracks only, as librespot's does,
each once.

## Problem

A probe on `PlaybackQueue`, context `t0 t1 t2`, 2026-09-29:

| Played | `history` |
|---|---|
| t0, then queued q0, then t1 | `[t0, t0]` |
| Previous twice from there | t0, then t0 again |
| From t0, queued q1 and q2, then on | `[t0, q1, t0]`, current t1 |

`advance` pushed the current track before it moved:

- **Into a queued track.** It pushed `currentUri`, which is the queued track playing, or the
  context track when none is. So a queued track followed by another was recorded, and the last
  one of a run was not.
- **Back into the context.** It cleared `userQueueCurrent` first, then pushed. `currentUri` was
  then the context track at `currentIndex`, the one pushed already when the queued track
  started, so it went in twice.

A third effect followed from the first: Previous from the second of two queued tracks popped the
first, which `backward()` could not find in the context. It returned that track to play and left
`currentIndex` where it was, so the queue reported the context track as current while the queued
one played.

## Solution

The plan left two choices open: keep only context tracks, like librespot, or keep everything
played.

**Context tracks only, like librespot.** Its `next_track` puts only context and autoplay tracks
in `prev_tracks`: "only add songs from our context to our previous tracks". Keeping everything
would need `backward()` to know that an entry was queued, so as to play it as a queued track
rather than look for it in the context; `PlaybackQueue` keeps the history as bare uris, so that
belongs with `plans/open/queue-rows-have-no-identity.md`. And this client reports the history as
its `prev_tracks`, where librespot's rule is the one other devices already see.

`pushHistory` records the context track at `contextPosition`, and nothing while a queued track
plays. `advance` clears the queued track with a `defer`, after its push, rather than before it.
So:

- context to queued: the context track is pushed, as before;
- queued to queued: nothing;
- queued back to the context: nothing, since the context track the run interrupted is there.

`backward()` needed no change: its comment already assumed that the entry before a queued track
names the context track to return to, and now it always does.

`plans/open/queue-rows-have-no-identity.md` said its history rework belonged with this plan,
because the history would need to know which entries were queued. It no longer does, so that plan
now says the history can become context indices on its own.

## Verification

- [x] Unit tests, the plan's three rows:
  - t0, q0, t1: the history is `[t0]`, and `recent()` lists t0 once. Previous from there goes
    to t0, then has nowhere to go.
  - t0, q1, q2: the history is `[t0]`; Previous from q2 returns to t0, with the queue on t0;
    and moving on from there plays t1, with the history `[t0]`.
- [x] Build, 443 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: play an album, queue a track from another album, and let it play into the album's
      next track. The Queue section lists the album's first track once above the current one,
      and Previous twice goes to it, then restarts it.
