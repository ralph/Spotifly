# A queued track handed over in a bare list is placed by its uri

Status: **Open**, not planned. Not reachable with the web player (measured); a phone queues into a
bare list (seen 2026-10-01), so it can be measured with one, and a Debug build now logs what a
handover carries, so no throwaway build is needed. What is left of
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

Not planned. Measure first, with a phone, which queues into a bare list. It needs someone with
the phone:

1. Run a Debug build of the Mac app, with its stderr kept (`open --stderr <file>`).
2. On the phone, start a bare list: search, then Play on the tracks section, or a list another
   device sent.
3. Queue a track on the phone and press Next until it plays.
4. Pick the Mac as the device on the phone.
5. Read the log's `DealerConnection] Transfer data: …` line, the transfer's `TransferState`
   whole as base64 (since 2026-10-01), and decode it: `echo <data> | base64 -d | protoc
   --decode_raw` (`brew install protobuf`). `3.2.5` are the context's pages, each with its
   tracks' uris and uids (`4.1`, `4.2`) or a `page_url`; `3.3` is the session's `current_uid`;
   `4.1` the queue and `4.2` whether a queued track plays. The parsed `TransferState` is logged
   next to it, as `SpircController] Command received: transfer(…)`.

If no context tracks come, the Mac has no list to play but the current track; if the session's
uid names a row, it is what the take-over could resume the list at.

## Verification

Not defined yet.
