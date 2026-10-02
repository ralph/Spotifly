# A handover of a track queued during autoplay names a station this Mac cannot play

Status: **Done** 2026-10-02, seen with the web player as the other device; see Progress. Found in
the altitude review of `plans/done/phone-takes-macs-autoplay-as-queued.md`.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`continuePlayback`,
`continueAutoplay`, `takeOverState`, `play`), `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift`
(`playAutoplay(after:)`), `Spotifly/SwiftLibrespot/Proto/TransferState.swift`
(`continuesAutoplay`, `sessionUid`), `Spotifly/SwiftLibrespot/Network/SPClient.swift`
(`resolveContext`, `nextPagePath`, `parseContextReport`)
Found: 2026-10-02, reviewing the handover this Mac writes during autoplay

## Summary

While a track queued during autoplay plays, a handover names the station as the context and the
queued track as the current one. This Mac took that for an ordinary context and played the
station's uri, whose resolve failed on its second page, so the take-over gave playback up. Play on
the Mac over the same state went on with the album instead of the station.

## Problem

Measured on 2026-10-02 with the web player in autoplay, a track queued there and played:
- **Its handover:** the station as the context (`spotify:station:album:<id>`, a radio's
  restrictions, `loading`, no pages), the album as `main_context`, `is_playing_queue`, the queued
  track as the queue's head and the current track (by gid), and `current_uid` the station's next
  row. The phone's handovers name `main_context` too (seen in its `transfer_data` the same day).
- **The reading:** `continuePlayback` went to `continueAutoplay` only on `currentIsAutoplay`, the
  current track's `autoplay.is_autoplay`. A queued track has `is_queued`, so the handover went to
  `play(uriOrUrl: "spotify:station:album:…", resumingAtUid:)`.
- **The station's resolve:** its first page answered (8776 bytes, 50 tracks) with a
  `next_page_url` of `hm://radio-apollo/v3/tracks/spotify:station:album:<id>?…`. `resolveContext`
  asked for that behind `context-resolve/v1/`, which answered 404, and the whole resolve failed:
  "Transfer failed to load: Context resolve failed: HTTP 404". librespot (`get_next_page`) and
  go-librespot (`hmRequestUrl`) ask spclient at the url's own path. Asked so, the second page
  answered 50 more as one page (`{next_page_url, tracks}`), and the third, at
  `hm://radio-router/…`, 404: a station names pages without end.
- **The 404 recorded in `plans/done/autoplay.md`** for a phone's station was this one: the first
  page had resolved there too.
- **Song radio** (Start Song Radio, `playRadio`, `spotify:station:track:<id>`) failed the same way
  on main: its second page was asked at `context-resolve/v1/hm://radio-apollo/…` and answered
  404, so it never played.
- **Play on the Mac** over such a mirrored state took the album as the context (the player state
  names the album), with the station's next row as the row to go on with, which the album does
  not have.

## Solution

- **A session that goes on in autoplay** (`TransferState.continuesAutoplay`), its row autoplay's:
  an autoplay track, or a queued track before autoplay's next row. A handover says the latter by
  the station as its context beside a `main_context`; a mirror by the session row's provider
  (`takeOverState`, which also takes the station from that row), the test this Mac's own
  handover writes by. A station played as it is plays as a context; whether a radio's handover
  names a `main_context` too is not measured, so only a queued track goes by it.
- **`continueAutoplay`** plays a queued track as queued, after the album's last row, with
  autoplay's rows behind it (`PlaybackQueue.playAutoplay(after:)`, which keeps them in order when
  shuffled), from the row the session goes on with (`sessionUid`). Rows the other device sent
  are used from that row (a mirror's, or this Mac's own handover's page); a handover without
  them gets a station asked for.
- **With no context resolved** to stand on (its resolve failed), the queued track goes in front
  of autoplay's rows as a context row, as `PlaybackQueue.start(in:queued:resumingAt:uids:)` puts
  one before a first row; found by `/code-review`, where the first station row was skipped.
- **Not the station as a context,** as librespot and go-librespot take a queued track: a station
  is resolved afresh with each request (a `salt` in its page urls), so the row a handover names
  is not among its rows; other devices would be told a radio, so this Mac's next handover would
  not say autoplay; and Previous would have no album to go back into.
- **Paging:** an `hm://` next page is asked of spclient at its path (`SPClient.nextPagePath`), and
  read as one page; a later page that fails leaves the pages before it. Only the first page
  failing fails the resolve. A station's pages are still fetched before it plays: two, 100
  tracks, about 0.4 s more than one, then the third's 404 ends it. The deeper form is fetching a
  next page when the queue nears its end, as librespot and go-librespot do; not built.

## Verification

- Unit tests: `TransferStateTests` (a queued track before the station's next row goes on in
  autoplay; one in a station played as it is, or in an album, does not), `MirroredQueueTests`
  (the same from a mirror), `AutoplayQueueTests` (a queued track taken over plays before
  autoplay's rows), `AutoplayHandoverTests` (this Mac's own handover reads back so), and
  `SPClientRequestTests` (an `hm://` next page at its path; a later page failing).
- Live with the web player; see Progress.

## Progress

- **Reproduced** (2026-10-02), with the merged build: the handover above failed with the
  next-page 404 and the Mac kept mirroring.
- **Built and seen** (2026-10-02):
  - **The station played as it is** (`SPOTIFLY_DEBUG_AUTOPLAY` on its uri): two pages, 100
    tracks, the third page's 404 left them, and it played, 0.72 s after the request.
  - **Song radio on main** (`spotify:station:track:…`): the second page's 404 failed it. On the
    branch: two pages, 100 tracks, playing 0.58 s after the request.
  - **After `/simplify`** (the queued track through `playAutoplay(after:)`): the handover again
    gave the queued track, the album behind it and a station of 50 ahead; the web player had
    stalled paused at 1.5 s, and the Mac took it over paused there.
  - **The handover:** the web player in autoplay, "Great Expectations" queued there and played,
    then this Mac picked. The Mac read `resumesInAutoplay`, resolved the album and a station of
    50, and played the queued track from 25.2 s. Its Queue section: the album's last track (C),
    the queued one playing (Q), then the station's tracks (A).
  - **Back to the web player,** which went on with the queued track at 1:14.
  - **Play on the Mac** after the web player let go: the mirrored queued track from 74.6 s, the
    album behind it, and the web player's own 50 station rows ahead, without asking for a
    station.
