# Previous goes back a track however far in the current one is

Status: **Done** 2026-10-03, verified live
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`previous()`, `rowBefore`)
Found: 2026-10-03, in `plans/done/seek-on-a-mirrored-track-fails.md`; the user asked for Spotify's
behaviour

## Summary

On this Mac, Previous went back to the track before whenever there was one, even minutes into the
current track. Spotify's clients restart the current track once it is a few seconds in.

## What Spotify's clients do

The web player, measured 2026-10-03 on an album, with this Mac quit:

- **About 1 s and 2 s in, playing:** Previous went to the track before, which played.
- **About 1 s in, paused:** the same, and the track before *played*.
- **About 4 s in, playing:** Previous restarted the track, which kept playing.
- **About 4 s in, paused:** it restarted the track, which stayed paused.
- **With no device active**, the track stopped at 0:00 with one before it: Previous went to the
  track before, which played.

librespot's `handle_prev` has the same threshold, 3 s (`position() < 3000`), though it keeps a
paused player paused on the track before.

## Solution

`LibrespotClient.previous()`:

- **From 3 s on** (`previousGoesBackWithinMs`), it seeks the track to 0, which keeps it playing
  or paused, as it does with no track before.
- **Before that**, it goes back as before, and the track before plays.
- **The position** is the pipeline's playhead, but only while the pipeline holds the track the
  queue stands on. During a load, the playhead is still the track left's, so Next then Previous at
  once would have read its 8 s and restarted instead of going back (found in review, from the
  code; the fixed case is verified below).
- **On a mirrored track** with nothing loaded here, within its first 3 s it takes the mirror over
  from the row shown before it (`rowBefore(mirrored:)`, the Queue section's last previous row),
  which plays. Past them, or with no row before, it loads the track paused at 0, as before.

Previous sent to another device is unchanged: that device applies its own rule.

## Verification

- [x] Build, 630 unit tests and `swiftformat --lint`, exit 0, no warnings. `MirroredQueueTests`
      cover `rowBefore`: the last shown row within 3 s, none from 3000 ms, none without a row
      before.
- [x] Live, Debug build of the branch, on the album `3aRP1Tgb46xxQp31ikuDNW`:
  - [x] A mirrored track at 10.9 s: Previous loads it paused at 0, as before.
  - [x] Playing, 70 ms into track 3 after Next: Previous goes back to track 2, which plays.
  - [x] Playing, 5 s into track 3: Previous restarts it, playing; the queue is unchanged.
  - [x] Paused at 5740 ms: Previous restarts the track, which stays paused.
  - [x] Paused at 957 ms: Previous goes back to track 1, which plays.
  - [x] A mirrored track paused at 767 ms, with track 1 before it: Previous takes the mirror over
        from track 1, which plays.
  - The paused and mirrored cases ran from a throwaway script hook calling `PlaybackViewModel`'s
    pause, resume, next and previous, never committed, as the screen had locked.
- [x] After the review's changes, the same hook: Next then Previous at once, 8349 ms into track 1,
      goes back to track 1, which plays; Previous playing at 3901 ms restarts; paused at 682 ms
      goes back, playing; paused at 4895 ms restarts, paused.
