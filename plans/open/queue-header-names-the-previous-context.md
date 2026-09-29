# The queue names the previous album while a bare list plays

Status: **Open**, not planned. Seen 2026-09-29 while testing #84.
Components: `Spotifly/Store/AppStore.swift` (`setQueue`), `Spotifly/Views/QueueListView.swift`
(`contextInfo`, `playingFromText`)
Found: 2026-09-29, testing #84: a list of three tracks sent to the Mac played under the header
"Wiedergabe von „Alive“", the album played before it.

## Summary

A list of tracks with no album or playlist behind it has an empty context uri. `AppStore.setQueue`
keeps the previous one when it is handed an empty uri, so the queue's header goes on naming the
album or playlist that played before, and links to it.

## Problem

- `setQueue` updates `queue.contextUri` only if the uri is "non-nil and non-empty", a rule from
  the Web API days, when an answer could leave the context out.
- The player now always says what it plays from, and an empty uri means a bare list: Play Tracks
  under search, and since #84 a list sent from another device.
- So `QueueListView.contextInfo` finds the old album in the store and shows it as "playing from",
  with a link to it.

## Solution

Not planned. Likely: take an empty uri as "no context" in `setQueue`, and have the header say
nothing about a context then, or name the list the way Spotify's clients do. Check first whether
any caller still passes an empty uri meaning "unknown".

## Verification

Not planned.
