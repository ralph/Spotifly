# A queued track handed over in a bare list is placed by its uri

Status: **Open**, not planned. Not reachable with the web player (measured); a phone queues into a
bare list (seen 2026-10-01), so it can be measured with one. What is left of
`plans/done/queued-track-handover-in-an-album.md`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`takeOver`, `playTracks`),
`Spotifly/SwiftLibrespot/Proto/TransferState.swift`
Found: 2026-09-30, measuring the handover of a queued track

## Summary

A bare list, such as Play Tracks under search or a list another device sends, has no context uri
to resolve. `takeOver` plays `contextTrackUris`, but the pages were empty in every transfer
measured, so a handover of one, queued track or not, may arrive with no list at all.

## Problem

Not measured, because the web player would not produce it (2026-10-01). Spotifly played a bare
list of five tracks, and the web player took it over and listed them. While it controlled
Spotifly playing that list, its row menu had no "Zur Warteschlange hinzufügen", which it had as
soon as Spotifly played an album instead; and while it held the list itself, it could not start
its audio from a synthetic click, and its controls did not respond. So no queued track, and no
handover of one, came of a bare list.

A phone does queue into a bare list: testing the take-over of one (2026-10-01, see
`plans/open/mirrored-queue-beyond-the-web-player.md`), a track was queued on the phone while it
held a list from search's Play Tracks. That was a take-over by Play on the Mac, which reads the
mirrored state, not a handover from the phone, which this plan is about.

What a transfer of a bare list carries in `context.pages`, and whether the session's
`current_uid` then names anything a list could be matched against, is still unknown.

## Solution

Not planned. Measure first, with a phone, which queues into a bare list: play one on it, queue a
track, Next into it, pick the Mac as the device, and log the transfer with a throwaway build
(`context.pages`, the session's `current_uid`, the queue). It needs someone with the phone.

## Verification

Not defined yet.
