# What the mirrored queue still takes on trust: repeat on a bare list, autoplay, other devices

Status: **Open**, in part. Next on a context's last track is done and seen with the web player
(2026-10-01); see Progress. The rest needs a phone or another device. From the altitude review
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
- **Next on a context's last track** (done; see Progress). While mirroring with repeat off,
  `nextTracks` is now empty on the context's last track, so `hasNext` greys the bar's Next.
  That matches the web player's visible queue. But a device with autoplay on would go on into
  autoplay, and the Mac can no longer ask it to. The cluster's `restrictions`
  (`disallow_skipping_next_reasons`) would say for sure, and the app does not parse them. Not
  checked what the web player allows there.
- **Other devices' rows.** librespot, as the other device, fills autoplay after a delimiter
  "to only display the current context" (`connect/src/state/tracks.rs`), and those autoplay
  rows may not be hidden. A phone was not measured either.
- **This Mac's own report**, for completeness: `PlaybackQueue.upcoming()` stops at the end of
  the context, even with repeat on, so other devices show no next iteration for the Mac, where
  librespot reports a delimiter and the next iteration. A gap, not a fault.

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
