# A queued track handed over in an album, or in a bare list, is placed by its uri

Status: **Open**, not planned. What is left of `plans/done/handover-edge-cases.md`; the album case
was measured, the bare list was not.
Components: `Spotifly/SwiftLibrespot/Proto/TransferState.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`takeOverQueued`, `takeOver`)
Found: 2026-09-30, measuring the handover of a queued track

## Summary

A handover while a queued track plays names the context row that comes next by its uid, and
Spotifly finds that row in a playlist's resolve answer. An album's answer carries no uids, so the
row is not found, and the queued track is placed by its uri as before.

## Problem

- **An album.** Measured on "Food In The Belly":
  - The web player played Messages (row 2), then Energy Song, queued from row 5.
  - The transfer's `current_uid` was `641b0e01bced253ac901`. Our resolve answer for the album
    has no uids to match it against.
  - Spotifly found Energy Song by its uri at row 5, and the context went on with row 6,
    passing over rows 3 and 4.
  - The web player's uids for the album's rows look like a playlist's, 20 hex characters. It got
    them from somewhere: perhaps its own resolve request, perhaps pathfinder's album tracks.
    Neither was checked.
- **A second way in.** Every transfer measured carried an undocumented field 6, which is not
  in librespot's `transfer_state.proto`. It looks like a play history: repeated entries with a
  uid (field 1), a uri (field 6) and a timestamp (field 9), the queued track among them with
  uid `q0`. The last entry before the queued track names the context track it interrupted,
  Messages here, and that row is where `rowBeforeResume` would have put the context.
- **A bare list** (Play Tracks under search, a list sent from another device). `takeOver` plays
  `contextTrackUris`, and pages were empty in every transfer measured, so a queued track in one
  is not placed either. Not measured.

## Solution

Not planned. Either give an album's rows the web player's uids, which first needs finding where
it gets them, or read field 6 for the last context track, which leans on a field no proto
documents.

## Verification

Not defined yet. The measurement to repeat: play an album's row in the web player, queue a later
row, Next into it, hand over, and compare the two queues.
