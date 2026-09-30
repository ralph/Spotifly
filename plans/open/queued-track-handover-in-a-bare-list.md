# A queued track handed over in a bare list is placed by its uri

Status: **Open**, not planned; not measured. What is left of
`plans/done/queued-track-handover-in-an-album.md`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`takeOver`, `playTracks`),
`Spotifly/SwiftLibrespot/Proto/TransferState.swift`
Found: 2026-09-30, measuring the handover of a queued track

## Summary

A bare list, such as Play Tracks under search or a list another device sends, has no context uri
to resolve. `takeOver` plays `contextTrackUris`, but the pages were empty in every transfer
measured, so a handover of one, queued track or not, may arrive with no list at all.

## Problem

Not measured. What a transfer of a bare list carries in `context.pages`, and whether the session's
`current_uid` then names anything a list could be matched against.

## Solution

Not planned. Measure first: play a bare list on another device, queue a track, Next into it,
hand over, and log the transfer.

## Verification

Not defined yet.
