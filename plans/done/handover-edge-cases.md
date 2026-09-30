# Handovers the uid does not place: a queued track, an album's relinked track, a bare list

Status: **Done** 2026-09-30, for a queued track in a playlist or Liked Songs, seen in the running
app. An album's relinked track was measured to need nothing. What is left, a queued track in an
album and a bare list, is `plans/open/queued-track-handover-in-an-album.md`.
Components: `Spotifly/SwiftLibrespot/Proto/TransferState.swift` (`contextResumeUid`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`takeOverQueued`, `queueState`),
`Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`rowBeforeResume`, `playQueued`)
Found: 2026-09-30, in the review of the handover fix

## Summary

A handover finds its row by the uid the transfer names, where the context lists it. Three
handovers were left without one. The first is placed now, the second turned out not to need a
uid, and the third is still open.

## Problem

- **While a queued track plays.** The transfer's current track is then the queue's head, with no
  uid that names a context row. `start` found it by its uri further on in the context, or put
  it in as the context's first row, and the context went on from there.
  - Measured with the web player: Liked Songs playing its second row, a track queued, Next into
    it, then handed over. Spotifly put the queued track in as row 0, marked C, and the context
    started again from its first track. The web player had the third row next.
  - The handover named the queued track by gid only. The uri rebuilt from it,
    `spotify:track:7zzoxJbgjme3366mOp5UnH`, is not the one Liked Songs lists for the same song,
    so matching by uri could not find it either.
  - The transfer's `current_session.current_uid` was `195f8110b593d39eb69b`. An earlier log of
    the same Liked Songs names that uid on Gold Lion, the third row: the row the context goes on
    with. librespot's `finish_transfer` reads it the same way. While the queue is playing, it
    takes the row `current_uid` names and starts the context on the row before it.
- **An album's relinked track.** An album's resolve answer has no uids, so a relinked track in an
  album can only be placed by its uri. Measured on "Food In The Belly": the album's resolve lists
  The Letter by its market id, `7FcObTmCbQYyC8qzlTL2SE`, the id the web player handed over.
  So the uri finds the row, and the handover played The Letter, then Messages. The transfer sent
  no pages of the context (`context.pages` was empty in all three transfers), so it has no
  listed uri to offer either.
- **A bare list.** Not measured; see the open plan.

## Solution

- **`TransferState.contextResumeUid`**: the session's `current_uid`, kept only while a queued track
  plays. While a context track plays, it only names that track again (measured: the album
  transfer's `current_uid` was its current track's uid).
- **`PlaybackQueue.rowBeforeResume(uid:uids:count:)`**: the row before the one the uid names. A
  queued track leaves the context there too, since Next into it keeps `currentIndex` on the
  context track it interrupted. It is nil for the first row, which has no row before it, and for
  a uid the context does not list.
- **`PlaybackQueue.playQueued(_:)`** plays a track as queued, now, the way Next into a queued track
  does: the context track goes into the history, and the context goes on after it.
- **`LibrespotClient.takeOverQueued`** resolves the context once and publishes the queue once
  the queued track is current. It falls back to where `start` puts the track when there is no
  row before, which is the album case.
- **The published queue labels its current track by where it came from**, `queue` or `context`,
  through `PlaybackQueue.currentProvider`. It said `context` always, so a queued track playing
  showed a C in the queue, whether handed over or reached by Next.

## Verification

- [x] Unit tests:
  - the transfer's resume uid comes through while the queue plays, and not otherwise;
  - the row before, and none for the first row, an unknown uid or an album's missing uids;
  - a queued track handed over plays as queued, the history holds the row before, and the
    context goes on at the row named.
- [x] Build, 467 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] In the running app, 2026-09-30, with the web player as the other device. The same Liked
      Songs handover as measured above:
  - Spotifly showed The Diamond Church Street Choir in the history;
  - "I Took A Pill In Ibiza" playing, marked Q;
  - then Gold Lion, "I Took A Pill In Ibiza" (row 4) and The Letter.
  - Next played Gold Lion. The Connect device was chosen by its name only.
