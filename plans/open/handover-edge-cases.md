# Handovers the uid does not place: a queued track, an album's relinked track, a bare list

Status: **Open**, not planned. From the altitude review of
`plans/done/handover-of-a-relinked-track-starts-at-the-top.md`; read from the code and
librespot, nothing observed.
Components: `Spotifly/SwiftLibrespot/Proto/TransferState.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (the transfer's take-over),
`Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`start`)
Found: 2026-09-30, in the review of the handover fix

## Summary

A handover now finds its row by the uid the transfer names, where the context lists it. Three
handovers are left without one.

## Problem

- **While a queued track plays.** The transfer's current track is then the queue's head, with no
  uid that names a context row and no index. `start` puts it in as context row 0, and the
  context goes on from its first track, the same symptom as the relinked track had. librespot
  uses the session's `current_uid` here, and takes the row before the one it names
  (`connect/src/state/transfer.rs`). What `current_uid` holds in this case is not measured.
- **An album's relinked track.** An album's resolve answer has no uids, so a relinked track in
  an album is still placed by uri alone. librespot has the same gap. The transfer's own page of
  context tracks might carry the listed uri beside the uid, which would find the row; the pages'
  uids are dropped today.
- **A bare list.** A transfer of a list with no context plays `contextTrackUris`, and the pages'
  uids are dropped there too. Not observed; such transfers are rare.

## Solution

Not planned. Measure first: a transfer while a queued track plays, and one of an album's
relinked track, logging the session's `current_uid` and the pages' rows.

## Verification

Not defined yet.
