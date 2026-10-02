# A phone that takes this Mac's autoplay over makes it a queued track

Status: **Open**, built 2026-10-02 and seen with the web player; the phone is still to see.
Measured with a phone on 2026-10-02, over three rounds, and the cause found in the cluster's
`transfer_data`; see Problem. Left from `plans/done/autoplay.md`.
Components: `Spotifly/SwiftLibrespot/Connect/SpircController.swift` (`handover(of:)`,
`buildDevice`), `Spotifly/SwiftLibrespot/Proto/TransferState.swift` (`serialized`,
`mainContextUri`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`continueAutoplay`)
Found: 2026-10-02, testing autoplay with a phone

## Summary

While an autoplay track plays on this Mac, a phone that picks itself takes that track over as a
queued one: provider `queue`, `is_queued`. It puts the album's last track after it again, then
its own recommendations. Play on the Mac afterwards takes over that state as it is. Everything
else about autoplay works; this is only what a phone makes of this Mac's report.

## Problem

Measured with a throwaway build logging this Mac's reported player state and the phone's
mirrored one:

- **Round 1:** the Mac reported the autoplay track at index 15 of a 15-track album. The phone
  made it queued, with the album's last track after it. librespot clears the index while an
  autoplay or a queued track plays; `reportedIndex` now does too.
- **Round 2,** no index, autoplay rows naming their station (`context_uri`, `entity_uri`): the
  phone named its context "Wiedergabe empfohlener Songs", yet still held the track as `queue`
  with `is_queued`, and "Talk About It", the album's last track, came again after it.
- **Round 3,** context rows naming their album too and queued rows `is_queued`, as librespot's
  and the phone's: the same. The album's rows had no uids that time, since the Mac's autoplay
  came from a handover (`continueAutoplay` skips the album's row uids); in round 2 they had them.
- **The web player** takes an autoplay track over as a context of its own (`spotify:track:…`)
  and goes on with its own autoplay from it, before and after the station was added.
  go-librespot notes that "a queued or autoplayed track is handed over on its own, with no
  context".

**What the phone reports during its own autoplay**, against this Mac's:

| | The phone | This Mac |
| --- | --- | --- |
| Context, index | the album, none | the same |
| The track | provider `autoplay`, `autoplay.is_autoplay`, the station as `context_uri` and `entity_uri`, `iteration=0`, `view_index=0`, `actions.skipping_next_past_track=resume` | the same, without `iteration`, `view_index` and `actions.*` |
| Previous rows | the album's, each with its uid, the album as `context_uri` and `entity_uri`, `iteration`, `view_index` | the album's, uid and `context_uri`/`entity_uri`, no `iteration`, `view_index` |
| Next rows | 49 autoplay rows with `view_index` 1…, then a hidden row `1` (uid `page1_0`), then a hidden `spotify:delimiter` (provider `autoplay`, uid `delimiter0`, `actions.advancing_past_track=pause`) | 50 autoplay rows, nothing after them |

**What the phone hands over** of its own autoplay: the station as the context
(`spotify:station:album:<id>`), no pages, and the track's uid as the session's; this Mac reads
that since 2026-10-02 (`contextBeforeAutoplay`). Neither librespot nor go-librespot writes the
cluster's `transfer_data`, so the phone decides from the reported player state, whose fields
this Mac does not parse all of (a session id, a play origin, restrictions).

**The cause** (2026-10-02, a throwaway build logging the cluster's `transfer_data`, field 5 of
the `Cluster` a PutState answers with). Every full client writes its own handover into its
`PutState` (`Device.transfer_data`, field 4): the web player did as soon as it played, and the
phone's handover above has the same shape. This Mac wrote none, and Spotify then builds one from
its player state. For the Mac's autoplay track it built:
- the album as the context, its page holding only the album's rows (`prev_tracks`' context rows;
  autoplay rows are left out), the session's `current_uid` that page's last row;
- the autoplay track as the current track, not on that page.

That is a track queued in front of the album's last row, which is what the phone made of it. On
an album's own track, the page held the album's rows and `current_uid` named the track, which is
why every other handover worked. The rows' metadata, index and delimiters (rounds 1 to 3, the
table) never reached the handover.

**What the web player writes** after taking an autoplay track over: the station as `context`
(`spotify:station:album:<id>`, restrictions of a radio, no pages), the track's uid as
`current_uid`, and the album as the session's `main_context` (field 8, with its metadata).
Neither librespot nor go-librespot reads `main_context`.

## Solution

While the session stands in autoplay, this Mac writes its own `transfer_data`, as a phone and the
web player write theirs (`SpircController.handover(of:)`, `TransferState.serialized`):
- the station as the context, with no pages: the device taking over resolves it, as it does a
  phone's handover;
- the album as `main_context`, with the resolver's metadata;
- the track, its uid as `current_uid`, and its metadata (`autoplay.is_autoplay`, the station);
- the queue, each track `is_queued`.

"In autoplay" is an autoplay track playing, or a queued track whose context row after it is an
autoplay row; then `current_uid` names that row, and the queued track is the queue's head as well
as the current track, as the phone wrote one. Otherwise nothing is written, and Spotify builds
the handover from the player state, as it did for every handover that worked.

Reading a handover, `continueAutoplay` takes the album from `main_context`, and only without one
from the station's uri (`contextBeforeAutoplay`).

Candidates 1 to 3 of the earlier list (`iteration` and `view_index` on rows, the phone's end of
the station, the album's row uids) were not needed: the handover never carried the rows.
Candidate 4, the station as the reported context, is what the handover now says, without changing
what other devices show while the Mac plays.

## Verification

- Unit tests (`AutoplayHandoverTests`): an autoplay track's handover reads back as the station
  with the album as `main_context`; a track queued during autoplay as the queue's head before the
  station's next row; outside autoplay, and without a station uri, none is written.
- With the web player (2026-10-02), see Progress.
- With your phone, still to see: picking the phone while this Mac plays autoplay shows the track
  as autoplay, with the station's tracks after it and not the album's last again.

## Progress

- **The cause measured** (2026-10-02), with a throwaway build; see Problem.
- **Written by hand first,** in that build: Spotify kept the Mac's `transfer_data` in place of
  its own (the PutState's answer carried it back, 369 bytes), and the web player, picked while
  the Mac played an autoplay track, took it over as the station for the first time: its own
  `transfer_data` named the station, the same track uid, and the album as `main_context`. Its
  queue panel listed the station's tracks after it, and no album track.
- **Built** (2026-10-02), and seen with the branch's build:
  - **Autoplay track:** Spotify kept the Mac's handover (the station, `main_context` the album,
    `current_uid` the track's uid); the web player took the track over at the Mac's position as
    the station.
  - **Back to the Mac** from the web player, picked by name: the handover named the album as
    `main_context`, the Mac resolved the album (2 tracks), lined up a station of 50 after it, and
    played the track from 59.9 s.
  - **Previous** into the album: Spotify built the handover itself again, the album as the
    context and the session at the album's track, so no station is left behind.
  - **A queued track during autoplay** (a track and an album queued, then Next): the Mac's
    handover named the station, the station's next row as `current_uid`, and 12 queued tracks.
    The web player played the queued track, the queued album, then the station's tracks.
