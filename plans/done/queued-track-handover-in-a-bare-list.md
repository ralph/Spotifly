# A queued track handed over in a bare list starts the list over

Status: **Done** 2026-10-02. Measured with a phone and the Debug build's handover log, and seen
fixed with the phone; see Verification. What was left of
`plans/done/queued-track-handover-in-an-album.md`.
Components: `Spotifly/SwiftLibrespot/Proto/TransferState.swift` (`contextTrackUids`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`playTracks`, `takeOver`)
Found: 2026-09-30, measuring the handover of a queued track

## Summary

A bare list has no context uri to resolve. Handed over while a queued track played, it went on
after that track at its first row, not after the row the sender had reached. The handover carries
the whole list, each row with a uid, and the session's `current_uid` names the row to go on with.
The take-over of a list now places the queued track by them, as the take-over of a context did.

## Problem

Measured on 2026-10-02 with a phone, from the Debug build's `Transfer data:` line, decoded:

1. Spotifly played search's Play Tracks for "oasis": 20 tracks, a bare list.
2. The phone, as a remote, queued a track, and Next went through it to the list's second row,
   "Rock 'n' Roll Star". Then the phone took playback, queued "I Wanna Be Sedated", pressed
   Next until it played, and handed playback back to the Mac 6 s into it.
3. The transfer:
   - no context uri;
   - one page with all 20 rows, each with a uid (`4.2`) and its gid (`4.3`), and no uri;
   - the current track the queued one, uid `q0`, with `is_playing_queue`;
   - the session's `current_uid` the third row's uid, "Little By Little": the row after the
     one the phone had reached.
4. `takeOver` played `playTracks(contextTrackUris, startingAtUri: queued)`. The queued track is
   not in the list, so `PlaybackQueue.start(in:index:uri:)` put it in front of the first row: the
   queue read nothing played and 20 to come. The Mac fetched "Don't Look Back In Anger", the list's
   first row, to play next.

**What the phone's search plays is not a bare list.** Its play button on an artist's tracks in
search played `spotify:list:popular-release-segments-main-roles:artist_<id>`: "Ramones Popular",
50 tracks. That uri resolves. Its handover carried an empty page, and the session's uid named a
row of the resolved list. The Mac went on as the phone would:
- the queued "Sheena Is a Punk Rocker" from 0:31;
- then "I Wanna Be Sedated" and "Pet Sematary", the rows after "Blitzkrieg Bop", which the
  phone had played before it.

So the one bare list known to reach this Mac is Spotifly's own: Play Tracks, handed to another
device and back. The recipe this plan had, "on the phone, start a bare list: search, then Play",
does not make one.

## Solution

- **`TransferState.contextTrackUids`:** each page row's uid beside its uri, none for a row without
  one. A row with neither uri nor gid is left out of both, so they stay aligned.
- **`playTracks` takes the rows' names that `play(uriOrUrl:)` takes:** `uids`, `startingAtUid`
  and `resumingAtUid`. Both now place the start with one function, `startingPoint`, where each
  wrote it out and only the context's had the queued case:
  - with a resume uid the list has, `PlaybackQueue.start(in:queued:resumingAt:uids:)` places the
    queued track: on the row before the named one, the track playing as queued;
  - otherwise `start(in:index:uri:uid:uids:)`, where in a list the playing row's uid now also
    picks among copies of a track;
  - with nothing named, the first track that plays.
- **`takeOver` passes the transfer's** uids, row uid and resume uid. The rows keep the sender's
  uids, so this Mac's reports name the rows as the sender did.

## Verification

- `TransferStateTests`:
  - a list's rows keep their uids beside them, and a row without a track is left out;
  - the measured case: a bare list's rows come with their uids, and the session names the row
    after the queued track. Its placement is `PlaybackQueueTests`' "a queued track handed over
    plays as queued, and the context goes on at the row named". `startingPoint` and the
    take-over have no unit test: the client is a singleton.
- 520 unit tests and the lint pass.
- Not changed: Play on the Mac while another device plays a bare list (`takeOverList`) still
  puts a queued track into the rows; see `plans/open/mirrored-queue-beyond-the-web-player.md`.
- **Seen with the phone** (2026-10-02):
  - **The round:** Play Tracks for "oasis" on the Mac. On the phone: take it over, Next once to
    "Rock 'n' Roll Star", queue "Sheena Is a Punk Rocker" and Next to it, then pick the Mac.
  - **The take-over:** the Mac took over the queued track at 0:18, with "Rock 'n' Roll Star"
    behind it, and fetched "Little By Little" ahead.
  - **Next:** played "Little By Little", then "Cigarettes & Alcohol" came, the list's order.
