# The playlist view builds its rows once per row

Status: **Open.** Recorded, not planned. Read from the code, not measured.
Components: `Spotifly/Views/PlaylistDetailView.swift` (`rows`, `normalTrackList`)
Found: 2026-09-29, in the efficiency review of #79

## Summary

`PlaylistDetailView.rows` is a computed property that maps every playlist item to its track,
looking each up in `store.tracks`. `normalTrackList` reads it once for its `ForEach` and again
inside every row, for `rows.count` in the divider check. The list is a `VStack`, not a lazy one.
So a body pass over a playlist of n tracks builds the array n + 1 times: O(n²) lookups, and n
array allocations.

## Problem

For a 2,000-track playlist that is about four million dictionary lookups per body pass, and a
body pass follows any change the view observes. It has not been measured in the running app.

## Solution

Not planned yet. Read `rows` once at the top of `normalTrackList`, `let rows = rows`, and use
that for the `ForEach` and the count. Measure a large playlist before and after with Instruments'
SwiftUI template.

## Verification

Not defined yet.
