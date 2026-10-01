# What the mirrored queue still takes on trust: repeat on a bare list, autoplay, other devices

Status: **Open**, not planned. From the altitude review of
`plans/done/mirrored-queue-runs-past-the-context.md`; read from the code and librespot, nothing
observed.
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

Not planned. The first is a change to the take-over. The others need a measurement first: the
cluster's rows and restrictions from a phone and from librespot, on a context's last track,
with autoplay on.

## Verification

Not defined yet.
