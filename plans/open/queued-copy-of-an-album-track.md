# A click on an album's copy of a queued track plays the queued one

Status: **Open**, not planned. What is left of `plans/done/queue-rows-have-no-identity.md`.
Measured with the web player; a phone not tried.
Components: `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`row(of:uid:nearest:in:)`)
Found: 2026-10-01, measuring the rows' uids

## Summary

The queue's rows carry uids, and a `skip_next` naming one goes to that row. An album's rows have
none, since the context resolver gives an album none, and for such a row the web player sends
none. So when a track is both queued and further on in the album, a click on the album's copy
names only the track, and the queue takes its first copy ahead, the queued one.

## Problem

- Measured 2026-10-01: a double-click on a row of an album in the web player's queue panel sent
  `skip_next` with the track and no uid. For a playlist's row it sent the row's uid, and for a
  queued row `q0`.
- `PlaybackQueue.row(of:uid:nearest:in:)` falls back to the track's first copy ahead when no
  uid is named, as librespot's `handle_next` does.

## Solution

Not planned. Two ways:

- **No uid as a value:** a `skip_next` that names no uid goes to the first row ahead that has
  none. Right for the web player, which sends a uid for every row that has one. Wrong for a
  device that never sends uids: it would pass over a queued copy it meant. So measure first
  what a phone sends for a queued row and for an album's row.
- **Give an album's rows uids**: pathfinder's `getAlbum` lists them (#116), at the cost of a
  request on every album play, and `PathfinderAlbumUnion.rowUids` keyed by row rather than by
  uri.

## Verification

Not defined yet.
