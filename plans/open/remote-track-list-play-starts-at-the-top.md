# A remote play of a bare track list starts at its first track

Status: **Open.** Recorded, not planned. Read from the code, not observed.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`playTracks`, the remote
`.play` command, `takeOver`), `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift`
(`start(in:index:uri:)`)
Found: 2026-09-29, in the review of #79

## Summary

Since #79, every start inside a *context* goes through one rule, `PlaybackQueue.start`: the
named track decides, the index picks the copy. Two paths that start a bare list of tracks,
with no context, still choose on their own.

## Problem

- **A remote `play` with a track list.** `executeRemoteCommand` hands a `play` with more than
  one `trackUris` to `playTracks(uris, positionMs:)`, which always starts at index 0. The
  command's `skip_to` (`playCommand.index`, `playCommand.trackUri`) is parsed and dropped. A
  sender that plays the third of five search results would start the first one here. Whether
  any Spotify client sends a bare list with a `skip_to` is not measured.
- **A handover of a bare list.** `takeOver` picks its start by hand:
  `transfer.contextTrackUris.contains(track) ? transfer.contextTrackUris : [track]`. A track
  missing from the list plays **alone**, where `start` would put it in front and keep the
  rest.

## Solution

Not planned yet. The likely shape: `playTracks` takes `index` and `startingAtUri` and routes
them through `PlaybackQueue.start`, and both paths call it. About ten lines, in one file. First
capture what a phone sends when it plays one track out of a list, since that decides whether
the first path is ever taken with a `skip_to`.

## Verification

Not defined yet.
