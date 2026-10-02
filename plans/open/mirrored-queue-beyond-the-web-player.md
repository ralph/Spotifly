# What the mirrored queue still takes on trust: autoplay, other devices

Status: **Open**, in part. Next on a context's last track, this Mac's own report of the next
round under repeat, and the take-over of a bare list are done and seen, the last two on a phone
(2026-10-01); see Progress. The mirror lists one round under repeat, seen with the web player
(2026-10-01). A phone with autoplay on was measured (2026-10-02): the mirror and Next work, and
what does not is this Mac's missing autoplay, now `plans/done/autoplay.md`. What is left needs a
device that names a reason not to skip next, or librespot as the other device. From the altitude
review of
`plans/done/mirrored-queue-runs-past-the-context.md`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirroredQueue`, the take-over
of a mirrored bare list), `Spotifly/ViewModels/PlaybackViewModel.swift` (`hasNext`),
`Spotifly/SwiftLibrespot/Connect/SpircController.swift` (this Mac's own report)
Found: 2026-09-30, in the review of the fix for the mirrored queue

## Summary

The mirrored queue leaves out the rows another device marks hidden, which is the rule the web
player's own queue follows. The web player's rows were measured, and a phone's were seen working
for a bare list and for the next round under repeat. What is still taken on trust: autoplay rows,
a device that refuses Next, and the next round of another device's context.

## Problem

- **A bare list taken over with repeat on:** done, seen on a phone; see Progress. Taking over a
  mirrored bare list played `[the current track] + nextTracks`. With repeat on, the next iterations are not
  hidden, so the list held the tracks two or three times, and local repeat then looped that
  longer list. The list should stop at the first delimiter, take the previous tracks as its
  start, and send queued rows to `replaceUserQueue`. Rare: a bare list is Play Tracks under search, or a list
  sent from another device.
  - Not reachable with the web player, measured 2026-10-01. Spotifly played a five-track bare
    list and the web player took it over (its queue listed the five under "Als Nächstes", with no
    context named). Its repeat did not respond, neither while it held the list nor while it
    controlled Spotifly playing it, and Spotifly has no repeat control of its own. Without
    repeat, taking the mirrored list back over played the same five tracks.
- **Next on a context's last track:** done; see Progress. Autoplay on was seen with a phone
  (2026-10-02). What is left of it: a device that does name a reason not to skip next, not seen.
- **Other devices' rows.** librespot, as the other device, fills autoplay after a delimiter
  "to only display the current context" (`connect/src/state/tracks.rs`), and those autoplay
  rows may not be hidden. A phone's were logged with autoplay on (2026-10-02; see Progress):
  its autoplay rows follow the album's last row with no delimiter between, and are shown.
- **The next round of another device's context:** done, one round under repeat; see Progress.
  The mirror listed it where that device does not hide it, while this Mac's own queue lists one
  round, as the web player's queue panel does.
- **This Mac's own report:** done; see Progress. `PlaybackQueue.upcoming()` stopped at the end
  of the context, even with repeat on, so other devices were shown no next iteration for the
  Mac, where librespot reports a delimiter and the next iteration.

## Solution

The take-over and this Mac's report are built; see Progress. The others need a measurement
first: the cluster's rows and restrictions from a phone and from librespot, on a context's last
track, with autoplay on. The web player's restrictions there can be read with this Mac
mirroring it; librespot never sets `disallow_skipping_next_reasons`
(`connect/src/state/restrictions.rs`), so for a librespot device they would say nothing.

## Verification

- The take-over: unit tests (`BareListTakeOverTests`), and seen on a phone; see Progress.
- Next on the last track, and the next round under repeat: see Progress.
- Autoplay on: a phone's rows logged on a context's last track; see Progress.
- What is left: a device that names a reason not to skip next, and librespot as the other
  device.

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
  delimiters by then. `takeOverState(of:)` reads it: the tracks played before the current one,
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
  - **A queued track playing** (2026-10-02) went into the list as one of its rows, where a
    context's take-over plays it as queued (`play(uriOrUrl:resumingAtUid:)`), and the handover
    of a bare list now does too (`plans/done/queued-track-handover-in-a-bare-list.md`).
    `takeOverState` now leaves it out of the rows and names the first row ahead that is not
    queued (`resumingAt`), with the rows' uids, and `playTracks` places it from those as for a
    handover. With no such row ahead, it goes into the list as before.
  - **Seen on a phone** (2026-10-02):
    - Play Tracks for "oasis" on the Mac. On the phone: take it over, Next once to
      "Rock 'n' Roll Star", queue "Sheena Is a Punk Rocker" and Next to it. Then pause and
      close the app, so no device was active.
    - Play on the Mac took the queued track over at 0:06, where it was paused. The queue had
      "Rock 'n' Roll Star" behind it and 18 rows ahead, the shape a handover of the same list
      gave, and the Mac fetched "Little By Little" as next.
  - **Seen on a phone** (2026-10-01, by hand): a list from search's Play Tracks, handed to the
    phone with repeat on and skipped twice, then taken back with Play on the Mac: each track was
    listed once and repeat came back to the first. A track queued on the phone first was in the
    Mac's queue after the take-over, not in the list.
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
- **One round in the mirror under repeat** (2026-10-01).
  - `mirroredQueue(of:)` leaves out the context's rows after the first `spotify:delimiter`,
    hidden or not, as the take-over already cuts there (`thisRound(of:)`), and as this Mac's own
    queue (`PlaybackQueue.Rounds.one`) and the web player's queue panel list. Rows after it that
    are not the context stay, since a device with autoplay on may list autoplay there
    (librespot does), which is unmeasured. It reads the rows, not the repeat option, so a
    device's repeat-one needs no rule of its own.
  - **Seen** with a throwaway log, the web player playing "Not Bad for New Jersey" from its
    first track: with repeat on it sent 80 next rows, 74 shown and 6 delimiters, and the mirror
    listed 10, the rest of the album, where it listed 74. With repeat off it sent the same 80,
    10 shown, and the mirror listed 10.
  - A phone's queue lists the next round (seen 2026-10-01), so the mirror now differs from a
    phone's own queue, and agrees with the Mac's and the web player's.
- **Autoplay on, a phone** (2026-10-02). A throwaway build, never committed, logged the rows
  this Mac mirrored. The account's autoplay was switched on on the phone.
  - **On an album's last track** ("The Final Frame", "Love & Hate"), the phone sent 52 next
    rows:
    - 50 with provider `autoplay`, not hidden, each carrying `autoplay.is_autoplay=true`,
      `context_uri` and `entity_uri` `spotify:station:album:<the album's id>`, `iteration=0`
      and a `view_index`;
    - then 2 hidden rows, the last a `spotify:delimiter` (uid `delimiter0`, provider
      `autoplay`, `actions.advancing_past_track=pause`).
    - No delimiter came between the album's last row and the first autoplay row. Next was not
      refused.
  - **The mirror** listed the 50 autoplay rows, marked A, as the phone's queue lists them.
  - **The bar's Next** was enabled, and sent `skip_next`. The phone went on to the first
    autoplay track, "Teardrop", still naming the album as its context, with 49 autoplay rows
    ahead.
  - **Play on the Mac,** with the phone paused and closed, took "Teardrop" over in the album.
    The track is not the album's, so it went in front of it, and the album followed from its
    first track: the take-over has no autoplay to go on with, and neither has this Mac when an
    album ends. Now `plans/done/autoplay.md`.
