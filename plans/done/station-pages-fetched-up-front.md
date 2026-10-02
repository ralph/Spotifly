# A station's pages are fetched before it plays, and it ends after them

Status: **Done** 2026-10-02: a station resolves a page at a time, fetches the next when its rows
run out, and goes on past its third page; see Progress. Left from
`plans/done/handover-of-a-track-queued-during-autoplay.md`.
Components: `Spotifly/SwiftLibrespot/Network/SPClient.swift` (`resolveContext`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`play(uriOrUrl:)`, `playRadio`,
`announceNextTrack`), `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift`
Found: 2026-10-02, in `/simplify` of the take-over of a track queued during autoplay

## Summary

`resolveContext` follows every next page before playback starts. A station names pages without
end, so Start Song Radio and a station played as a context wait for two pages and a third that
fails, and play their 100 tracks and stop.

## Problem

- **Measured on 2026-10-02:** the resolver's page (50 tracks), `hm://radio-apollo/v3/tracks/…`
  (50 more), then `hm://radio-router/v3/tracks/…`, answered 404, which ends the paging.
  Playback started 0.58 to 0.72 s after the request; one page takes about 0.27 s.
- **The tail:** a later page that hangs waits out its 20 s deadline before the pages so far play,
  and a 5xx is asked again after 0.25 s and 1 s.
- **The end:** after the last fetched row, nothing comes. Autoplay isn't asked for after a station
  (go-librespot's rule), so the radio stops after about 6 hours.
- **The third page's 404** (measured 2026-10-02 with a throwaway build that tried variants): the
  second page names the third at `hm://radio-router/v3/tracks/…`, which spclient answers 404.
  The same url at `radio-apollo` answers 50 new tracks and names a fourth at `radio-router`
  again. Without its `prev_tracks`, `radio-apollo` answers the station from its first track
  again, so they carry the station on.
- librespot never calls its `get_next_page`. go-librespot fetches a next page when the queue
  reaches it (`ContextResolver.Page`).

## Solution

- **`SPClient.resolveContext(_:pageLimit:)`** follows a context's pages up to its limit and names
  the page after them (`ResolvedContext.nextPageUrl`). A station's limit is one page; any other
  context's stays ten, so shuffle and repeat still have all of a playlist's rows.
- **`SPClient.resolvePage(_:)`** fetches a named page. `nextPagePath` asks a `radio-router` page at
  `radio-apollo`.
- **`PlaybackQueue`** keeps the url (`nextPageUrl`): `setContext(nextPage:)` sets it, a rewind
  keeps it, `takeNextPage()` takes it once, and `appendPage` adds the rows to the context's own,
  after the rows not yet played when shuffled.
- **`LibrespotClient.lineUpNextPage`**, beside `lineUpAutoplay` where nothing comes after the
  track playing: the page is fetched, appended if the same context still plays, and published,
  so its first track is fetched ahead.

## Verification

- Unit tests: `SPClientRequestTests` (a station resolves one page and names the next, asked at
  `radio-apollo` for a `radio-router` url; a playlist follows its pages), `StationPageQueueTests`
  (a page's rows join the context's own; another context drops the page, a rewind keeps it;
  shuffled, after the rows not yet played).
- Live: see Progress.

## Progress

- **Built and seen** (2026-10-02), Start Song Radio's station through `SPOTIFLY_DEBUG_AUTOPLAY`:
  - one request, playing 0.31 s after it (0.58 s with three requests before), 50 tracks and
    "more to come";
  - its last row played from the Queue section: the second page (`radio-apollo`) was fetched as
    it started, 50 more tracks, and the queue went from 0 ahead to 50;
  - the last row again: the third page, named at `radio-router`, was asked at `radio-apollo` and
    answered 50 more.
- **A 150-track playlist** resolved in one request with no next page, so other contexts are as
  before.
