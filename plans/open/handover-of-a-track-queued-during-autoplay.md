# A handover of a track queued during autoplay names a station this Mac cannot play

Status: **Open**, not planned. Inferred from the code on 2026-10-02, in the altitude review of
`plans/done/phone-takes-macs-autoplay-as-queued.md`; not seen live.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`continuePlayback`,
`continueAutoplay`), `Spotifly/SwiftLibrespot/Proto/TransferState.swift`
Found: 2026-10-02, reviewing the handover this Mac writes during autoplay

## Summary

While a track queued during autoplay plays, a handover names the station as the context and the
queued track as the current one. This Mac takes such a handover to an ordinary context and plays
the station's uri, which resolves to nothing, so the take-over likely fails.

## Problem

- **The shape:** this Mac writes it since the plan above (the station as `context`, the album as
  `main_context`, `is_playing_queue`, `current_uid` the station's next row). The web player and a
  phone write their own autoplay handovers the same way, so theirs likely does too in that state;
  not measured.
- **The reading:** `continuePlayback` goes to `continueAutoplay` only on `currentIsAutoplay`,
  which is the current track's `autoplay.is_autoplay`. A queued track has `is_queued` instead, so
  the handover goes to `play(uriOrUrl: "spotify:station:album:…", resumingAtUid:)`.
- **The station's uri** resolves to a 404 and gets a 204 from autoplay (measured 2026-10-02, in
  `plans/done/autoplay.md`), so that play has no tracks to stand on.
- **Play on the Mac** over such a mirrored state goes through `takeOverState`, whose context is
  the album the player state names, with the queued track current and the station's next row as
  `contextResumeUid`, which is not one of the album's rows. What it plays then is to be seen.

## Solution

Not planned. A sketch, from the review:
- `TransferState` names the context autoplay followed in one place: `mainContextUri`, or else the
  station's uri without `station:` (`contextBeforeAutoplay`), or nil.
- `continuePlayback` goes to `continueAutoplay` whenever that is set, not only for an autoplay
  track.
- `continueAutoplay` plays a queued current track as queued, then the station's rows from
  `contextResumeUid`.

## Verification

Not defined yet: at least, with the web player in its own autoplay, a track queued there and
played, picking this Mac plays that track and then the station.
