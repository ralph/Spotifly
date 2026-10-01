# What the mirrored queue still takes on trust: repeat on a bare list, autoplay, other devices

Status: **Open**, in part. Next on a context's last track, and this Mac's own report of the next
round under repeat, are done and seen with the web player (2026-10-01); see Progress. The rest
needs a phone or another device. From the altitude review
of `plans/done/mirrored-queue-runs-past-the-context.md`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirroredQueue`, the take-over
of a mirrored bare list), `Spotifly/ViewModels/PlaybackViewModel.swift` (`hasNext`),
`Spotifly/SwiftLibrespot/Connect/SpircController.swift` (this Mac's own report)
Found: 2026-09-30, in the review of the fix for the mirrored queue

## Summary

The mirrored queue now leaves out the rows another device marks hidden, which is the rule the
web player's own queue follows. Only the web player's rows were measured. Three things are
taken on trust.

## Problem

- **A bare list taken over with repeat on.** Taking over a mirrored bare list plays
  `[the current track] + nextTracks`. With repeat on, the next iterations are not hidden, so the
  list holds the tracks two or three times, and local repeat then loops that longer list. The
  list should stop at the first delimiter, take the previous tracks as its start, and send
  queued rows to `replaceUserQueue`. Rare: a bare list is Play Tracks under search, or a list
  sent from another device.
  - Not reachable with the web player, measured 2026-10-01. Spotifly played a five-track bare
    list and the web player took it over (its queue listed the five under "Als Nächstes", with no
    context named). Its repeat did not respond, neither while it held the list nor while it
    controlled Spotifly playing it, and Spotifly has no repeat control of its own. Without
    repeat, taking the mirrored list back over played the same five tracks.
- **Next on a context's last track:** done; see Progress. What is left of it: a device with
  autoplay on, and one that does name a reason not to skip next, neither seen.
- **Other devices' rows.** librespot, as the other device, fills autoplay after a delimiter
  "to only display the current context" (`connect/src/state/tracks.rs`), and those autoplay
  rows may not be hidden. A phone was not measured either.
- **This Mac's own report:** done; see Progress. `PlaybackQueue.upcoming()` stopped at the end
  of the context, even with repeat on, so other devices were shown no next iteration for the
  Mac, where librespot reports a delimiter and the next iteration.

## Solution

Not planned. The first is a change to the take-over. The others need a measurement first: the
cluster's rows and restrictions from a phone and from librespot, on a context's last track,
with autoplay on.

## Verification

Not defined yet, beyond Progress.

## Progress

- **Next on a context's last track** (2026-10-01).
  - **Measured** with a build that logged the mirrored state's `restrictions`, the web player
    playing "Fashion Nugget"'s last track, repeat off, nothing queued:
    - Its restrictions named reasons for resuming, playback speed, modes, signals and the
      sleep timer, and **none for Next** (`disallow_skipping_next_reasons` is field 7).
    - Its next rows were a delimiter and the album again, every one hidden, and no autoplay
      rows: autoplay is off for this account, so its case stays unmeasured.
    - Its own Next went back to the album's first track, paused. The restrictions then named
      `already_paused` and `no_prev_track`: they say what cannot be done, and Next could.
  - **So Next is no longer greyed for want of a listed next track.** `PlaybackState.canSkipNext`
    is true for this Mac, whose Next on a context's last track goes back to the first, paused
    (`rewindContext`), as the web player's does, and for another device unless its
    restrictions name a reason not to skip next (`PlayerState.disallowsSkippingNext`, field 17,
    its field 7). `PlaybackViewModel.hasNext` is that, wherever a track is current. It used to
    be "the queue lists a next track", which greyed Next on the last track for local playback
    too.
  - **Seen** in the running app: mirroring the web player on the album's last track, the bar's
    Next was enabled, and pressing it sent `skip_next`, after which the web player stood on the
    first track, paused. Played on the Mac, Next on the last track went back to the first,
    paused.
  - **Not seen:** a device that does name a reason, and autoplay on.
  - **Previous, not changed:** another device's restrictions name `no_prev_track` on a first
    track (field 6), where the mirrored previous rows are empty too, so `hasPrevious` agrees
    with it there. Reading field 6 into a `canSkipPrevious` would let Previous restart the
    track at once for a device that refuses, where it now sends `skip_prev`, is refused, and
    seeks; and it would cover repeat wrapping back from a first track. Neither is measured.
- **This Mac's own report of the next round** (2026-10-01).
  - Under repeat, other devices are told the context again after its end, as librespot's
    `fill_up_next_tracks` tells them: a hidden `spotify:delimiter` row named `delimiter0`, then
    the context from its start, as often as the 50 rows leave room for
    (`PlaybackQueue.upcoming(rounds: .asReported)`; the row is `QueueItem.hidden`, sent as
    `ProvidedTrack.isHidden`). Shuffled, the next round's order is drawn only when it starts,
    so it is not listed.
  - A jump another device names goes into the next round too, where a track behind the current
    one used to be found nowhere ahead (`skip(toUpcoming:uri:uid:)`).
  - The fetch-ahead gets the first track on the last one, so the wrap is gapless; it used to
    get nothing there.
  - The app's own queue lists one round, as before, as the web player's own queue panel does
    (below); the bar's "n/m" counts its rows. The mirror of another device still lists the next
    round where that device does not hide it, as `MirroredQueueTests` has it, so the two differ:
    left open.
  - **Seen:** "Not Bad for New Jersey" on the Mac, its last track, repeat on from the web player.
    A throwaway log, never committed, showed the report: `delimiter0` with `hidden: true`, then
    track 1, 2, 3 with their row uids. "Fetching … ahead" named track 1 right after the
    handover, and the end of the last track went on to track 1 without a gap.
  - **What the web player shows:** no next round, even of its own playback on the same track
    with repeat on, so its queue panel could not show the Mac's either.
  - **Seen on a phone** (2026-10-01, by hand): on an album's last track with repeat on, the
    phone's queue listed the album again after it, and a track tapped there played on the Mac.

