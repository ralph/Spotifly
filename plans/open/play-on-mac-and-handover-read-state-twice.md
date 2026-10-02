# Play on the Mac and a handover read another device's state two ways

Status: **Open**, not planned. From the altitude review of the take-over of a queued track in a
mirrored bare list (2026-10-02), which left it out of that change: it reworks the handover path
seen working on a phone that day.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`resume()`, `takeOverList`,
`takeOver(_:)`), `Spotifly/SwiftLibrespot/Proto/TransferState.swift`
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
  and the take-over of a bare list both replace it. Not seen yet: it needs a phone, a track
  queued there while an album plays, the phone paused and closed, and Play on the Mac.
- **Two snapshots of one moment.** `resume()` reads `latest.queue` for a context and
  `mirroredRemote` for a list.

## Solution

Not planned. The review's proposal:
1. One reader of the mirrored `PlayerState` into a `TransferState`, or a struct like it: the
   rows and their uids (only a bare list uses them), the current row's uid, the queued rows,
   and the resume uid. `takeOverList`'s rules move into it, the fallback for a queued track with
   no row after it included.
2. `takeOver(_:)`'s load moves into a function both use: it replaces the user queue, then plays
   a context through `play(uriOrUrl:)` or a list through `playTracks(_:uids:…)`.
3. `resume()` sets the options and calls it.

What differs and has to be kept: a handover reports this Mac active before loading and gives
playback up again when the load fails, while `resume()` throws to its caller; and `resume()`
takes the mirrored position as it is, where a handover carries it forward from its timestamp.

## Verification

Not defined yet. At least: the `takeOverList` tests carried over to the reader; with a phone, the
three take-overs by Play (a context track, a queued track in a context, a bare list), and a
handover of each.
