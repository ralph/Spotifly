# A station's pages are fetched before it plays, and it ends after them

Status: **Open**, not planned. Left from `plans/done/handover-of-a-track-queued-during-autoplay.md`
(2026-10-02).
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
- librespot never calls its `get_next_page`. go-librespot fetches a next page when the queue
  reaches it (`ContextResolver.Page`).

## Solution

Not planned. A sketch:
- `resolveContext` returns after the first page, with the next page's url.
- The queue keeps that url, and the client fetches the next page when nothing comes after the
  track playing, where `lineUpAutoplay` asks for autoplay today, and appends its rows.

## Verification

Not defined yet: at least, Start Song Radio plays after one page, and goes on past 50 tracks.
