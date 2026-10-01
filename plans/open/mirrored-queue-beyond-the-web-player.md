# What the mirrored queue still takes on trust: repeat on a bare list, autoplay, other devices

Status: **Open**, in part. The first item, the take-over of a bare list, is built and
unit-tested (2026-10-01), but not seen, since the web player gives a bare list no repeat; see
Progress. The others need a measurement; see Solution. From the altitude review of
`plans/done/mirrored-queue-runs-past-the-context.md`.
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
- **Next on a context's last track.** While mirroring with repeat off, `nextTracks` is now empty
  on the context's last track, so `hasNext` greys the bar's Next. That matches the web player's
  visible queue. But a device with autoplay on would go on into autoplay, and the Mac can no
  longer ask it to. The cluster's `restrictions` (`disallow_skipping_next_reasons`) would say
  for sure, and the app does not parse them. Not checked what the web player allows there.
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

## Progress

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
