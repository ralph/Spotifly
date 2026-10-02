# A phone that takes this Mac's autoplay over makes it a queued track

Status: **Open**, not planned. Measured with a phone on 2026-10-02, over three rounds; see
Problem. Left from `plans/done/autoplay.md`.
Components: `Spotifly/SwiftLibrespot/Connect/SpircController.swift` (the reported player state,
`provided`), `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`reportedIndex`,
`upcoming(rounds: .asReported)`), `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift`
(`continueAutoplay`)
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

## Solution

Not planned. Candidates, each to try with a phone, the way the rounds above went:
1. `iteration` and `view_index` on every row, as the phone's.
2. The station's end as the phone ends it: the hidden `page1_0` row and an `autoplay`
   delimiter after the autoplay rows.
3. The album's row uids in `continueAutoplay`, as `play(uriOrUrl:)` fetches them.
4. The station as the context while an autoplay track plays, as the phone's handover names it
   and go-librespot plays it.

## Verification

Not defined yet: at least, picking the phone while this Mac plays autoplay shows the track as
autoplay, with the station's tracks after it and not the album's last again.
