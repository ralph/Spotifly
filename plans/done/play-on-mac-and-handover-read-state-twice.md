# Play on the Mac and a handover read another device's state two ways

Status: **Done** 2026-10-02. The bug was reproduced with the web player and seen fixed, along with
the other take-overs and a handover; see Verification. From the altitude review of the take-over
of a queued track in a mirrored bare list (2026-10-02), which left it out of that change.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`resume()`, `takeOverState`,
`continuePlayback`, `takeOver(_:)`), `Spotifly/SwiftLibrespot/Proto/TransferState.swift`
Found: 2026-10-02, in `/simplify` of the take-over of a queued track in a mirrored bare list

## Summary

A handover reads one `TransferState` and branches only on where the rows come from: a resolve
for a context, the sent rows for a bare list. Play on the Mac, taking over another device's
mirrored playback with no device active (`resume()`), reads the same facts itself, in three
branches and from two snapshots. Its context branch for a context track does not carry the
other device's queue over, which a handover does.

## Problem

- **One rule, written twice.** "The current track is queued: the queued rows ahead go to the
  queue, and the list goes on at the first row that is not queued" is in `resume()`'s context
  branch, read from the published `QueueState` (`prefix` of queued rows), and in
  `takeOverList`, read from the mirrored `PlayerState` (`filter` of queued rows in this round).
  A fix to one does not reach the other.
- **The queue is not carried over for a context track.** With a context track playing on the
  other device, `resume()` calls `play(uriOrUrl:)` without `replaceUserQueue`. The other
  device's queued rows ahead are not taken over, and an older local queue stays. A handover
  and the take-over of a bare list both replace it. Reproduced with the web player
  (2026-10-02):
  - **Before Play:** it played "Better Before", track 2 of an 11-track album, with track 1
    queued, and was then released. The Mac mirrored 10 rows ahead: the queued one and 9.
  - **After Play on the Mac:** 9 rows were ahead, and the queued track was gone.
- **Two snapshots of one moment.** `resume()` reads `latest.queue` for a context and
  `mirroredRemote` for a list.

## Solution

The review's proposal, built:
1. **`LibrespotClient.takeOverState(of:)`** reads the mirrored `PlayerState` into a
   `TransferState`: the context, the options, the position, the current track and its row's uid,
   the queued rows ahead, and while a queued track plays, the uid of the row the context goes on
   with. For a
   bare list, also the rows with their uids, and which row is the current one
   (`TransferState.currentRow`, new; a handover's pages do not say). `takeOverList`'s rules
   moved into it, the fallback for a queued track with no row after it included.
2. **`continuePlayback(of:positionMs:paused:)`** is `takeOver(_:)`'s load, which both now use.
   It sets the options, replaces the user queue with the other device's, then plays a context
   through `play(uriOrUrl:)` or a list through `playTracks(_:uids:…)`.
3. **`resume()`** reads the mirror with `takeOverState` and calls it. It keeps what differs: it
   throws to its caller where a handover gives playback up again, and it takes the mirrored
   position as it is, where a handover carries it forward from its timestamp.

## Verification

- **Unit tests:** `MirroredQueueTests`, the `takeOverList` tests carried over to
  `takeOverState`, plus one for a context:
  - its queued rows ahead and the current row's uid;
  - and a queued track playing names no current row's uid.
  525 tests and the lint pass.
- **Seen with the web player** (2026-10-02), with Play pressed in Spotifly after the web player
  was released (navigated away):
  - **A context track, with a track queued (the bug):** "Pearls" played with track 1 queued; 9
    rows ahead before and after Play, and the Mac fetched the queued track as next.
  - **A queued track in a context:** "The Big Sleep", then the queued "Not Bad for New Jersey"
    by Next. Play on the Mac played it as queued with "The Big Sleep" behind it, 7 rows ahead,
    and fetched "On Good Terms", the row after "The Big Sleep".
  - **A handover** (`SPOTIFLY_DEBUG_TRANSFER_HERE_AFTER`) of "The Big Sleep" with track 1
    queued: taken over at 0:09, 8 rows ahead, and the queued track fetched as next.
- **Not seen here:** a bare list, which the web player cannot make; the take-over code for it
  is `takeOverList`'s, moved, and its tests carried over. The phone round in the PR covers it.
