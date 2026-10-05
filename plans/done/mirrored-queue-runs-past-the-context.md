# While another device plays, the queue runs on past the end of its context

Status: **Done** 2026-09-30. Measured from the web player's cluster, unit-tested, and seen in the
running app with the web player as the other device; see Verification.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirror`, `mirroredQueue`)
Found: 2026-09-30, testing #94 with the web player as the other device

## Summary

The web player played "Not Bad for New Jersey", an album of 11 tracks, with repeat off. Its own
queue ended with track 11, "Wolf by the River". The Mac's Queue section, mirroring it, listed
the album again after track 11, from its first track on. The same happened for "Cold Fact":
12 tracks, and the log said `prev=0, current=1, next=74`. Now the Mac's queue ends where the
web player's does.

## Problem

`LibrespotClient.mirror` published the cluster's `next_tracks` as they were, and `QueueService`
kept every row whose uri is a track.

### What the web player sends

Measured 2026-09-30 with a temporary log of each mirrored row, for the 11-track album:

- Rows 0 to 9 are the album's tracks after the current one, each with `iteration` `0`.
- Row 10 is `spotify:delimiter`, uid `delimiter0`, provider `context`, `hidden` `true`, as
  librespot builds it (`connect/src/state/tracks.rs`, `new_delimiter`).
- Then the album again, `iteration` `1`, another delimiter, the album as `iteration` `2`, and so
  on, for repeat to play.
- **With repeat off**, every row from the first delimiter on is `hidden` `true`.
- **With repeat on**, only the delimiters are; the next iterations are not.

The app dropped the delimiter row, since it is not a track, and showed the hidden iterations as
if they came next.

The cluster also names the context in its metadata, `context_description`; see
`plans/done/queue-header-names-no-liked-songs.md`.

## Solution

`LibrespotClient.mirroredQueue(of:current:)` builds the mirrored `QueueState`, and leaves out
every row, next or previous, whose metadata has `hidden` `true`. That is the rule the web
player's own queue follows: with repeat off the queue ends with the context's last track, and
with repeat on it goes on into the next iteration, without its delimiters. The queue building
moved out of `mirror` into that static function so it can be tested.

The review of it found what the rule still takes on trust: a bare list taken over with repeat
on, Next on a context's last track while another device has autoplay, and the rows of devices
other than the web player. See `plans/done/mirrored-queue-beyond-the-web-player.md`.

## Verification

- [x] Measured, as above.
- [x] Unit tests, in the measured shape: with repeat off the queue ends with the context's last
      track; with repeat on the next iteration shows without its delimiters; a hidden row
      among the previous tracks is left out.
- [x] Build, 452 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [x] Live, 2026-09-30, the web player holding "Not Bad for New Jersey": the Mac's queue ends
      with track 11, "Wolf by the River", and the bar says "1/11". With repeat on, the album
      follows again after it, with no empty row.
