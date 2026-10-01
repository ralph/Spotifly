# What the mirrored queue still takes on trust: repeat on a bare list, autoplay, other devices

Status: **Open**, in part. Next on a context's last track is done and seen with the web player
(2026-10-01). The take-over of a bare list is built and unit-tested, but not seen, since the web
player gives a bare list no repeat. See Progress; the rest needs a phone or another device. From
the altitude review of `plans/done/mirrored-queue-runs-past-the-context.md`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirroredQueue`, the take-over
of a mirrored bare list), `Spotifly/ViewModels/PlaybackViewModel.swift` (`hasNext`),
`Spotifly/SwiftLibrespot/Connect/SpircController.swift` (this Mac's own report)
Found: 2026-09-30, in the review of the fix for the mirrored queue

## Summary

The mirrored queue now leaves out the rows another device marks hidden, which is the rule the
web player's own queue follows. Only the web player's rows were measured. Three things are
taken on trust.

## Problem

- **A bare list taken over with repeat on** (built; see Progress). Taking over a mirrored bare
  list played `[the current track] + nextTracks`. With repeat on, the next iterations are not
  hidden, so the list held the tracks two or three times, and local repeat then looped that
  longer list. The list should stop at the first delimiter, take the previous tracks as its
  start, and send queued rows to `replaceUserQueue`. Rare: a bare list is Play Tracks under search, or a list
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
- **This Mac's own report**, for completeness: `PlaybackQueue.upcoming()` stops at the end of
  the context, even with repeat on, so other devices show no next iteration for the Mac, where
  librespot reports a delimiter and the next iteration. A gap, not a fault.

## Solution

The first is a change to the take-over, now built; see Progress. The others need a measurement
first: the cluster's rows and restrictions from a phone and from librespot, on a context's last
track, with autoplay on. The web player's restrictions there can be read with this Mac
mirroring it; librespot never sets `disallow_skipping_next_reasons`
(`connect/src/state/restrictions.rs`), so for a librespot device they would say nothing.

## Verification

- The take-over: unit tests (`BareListTakeOverTests`). Seen in the running app only once a device
  gives a bare list repeat: Spotifly plays Play Tracks under search, the device takes it over,
  repeat on, a few tracks in, and the Mac takes it back. The queue lists each track once, and
  repeat reaches the tracks before the current one; Previous restarts the track.
- Next on the last track: see Progress.

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
- **The take-over of a bare list** (2026-10-01). `mirror(_:deviceActive:)` keeps the remote
  player state it mirrored (`mirroredRemote`), since the queue view's rows have lost the
  delimiters by then. `takeOverList(of:)` reads it: the tracks played before the current one,
  the current one, and the rows after it up to the first `spotify:delimiter`. Queued rows go to
  `replaceUserQueue`, as a handover's do, and rows the sender hides are left out; so are the
  tracks before the last delimiter behind it, should a device keep an iteration there.
  `resume()` plays that list from the current track, where it played `[current] + nextTracks`.
  `mirroredRemote` is written with the snapshot's mirrored playback, so it is always there for
  a take-over. The tracks before go in so repeat loops the whole list, not its tail; the
  history starts empty, as after a handover, so Previous restarts the track.
  - **Its limits:** the cluster's previous rows are a window of ten (librespot's
    `SPOTIFY_MAX_PREV_TRACKS_SIZE`), so a list taken over further in than that loses its
    start, and repeat does not come back to it; a bare list carries no pages to read it from.
    And a queued track playing when the list is taken over goes into the list as one of its
    rows, as the handover's `playTracks` puts it in, where a context's take-over plays it as
    queued (`play(uriOrUrl:resumingAtUid:)`). Giving `playTracks` that start would serve both.
