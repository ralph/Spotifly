# Artwork that did not load keeps spinning after the network is back

Status: **Done** 2026-09-29 (#98). The mechanism checked with a probe against a local server; not
yet seen with the network actually dropped; see Verification.
Components: every `AsyncImage` in `Spotifly/Views`: `AlbumDetailView`, `ArtistDetailView`
(twice), `PlaylistDetailView`, `LibraryListView`, `TrackRow`, `NowPlayingBarView`,
`Components/CardArtwork.swift`, `SidebarView`; new: `Spotifly/NetworkMonitor.swift`,
`Spotifly/Views/Components/RetryingAsyncImage.swift`, `Spotifly/Views/Components/InlineLoadError.swift`
Found: 2026-09-29, testing #82's check 4: Wi-Fi off, open an album, Wi-Fi on, Try again

## Summary

Artwork that did not load while the network was down does not come back when it returns. The
album page's track list recovered through its Try again. The cover above it went on spinning,
because nothing asks for it again.

## Problem

### What was seen

- **Offline.** "Anthology 4" (The Beatles), from the library but never opened that session,
  was opened with Wi-Fi off. The header showed the name, the artist, "0 Tracks" and the date.
  The track section said "Es besteht anscheinend keine Verbindung zum Internet." with
  Erneut versuchen. The cover was a spinner.
- **Back online.** Wi-Fi was turned back on and Erneut versuchen pressed. The track list
  loaded all 36 tracks and the header said "36 Tracks • 1 hr 59 min". The cover was **still
  a spinner**.

### Why, as read from the code

- **What the spinner means.** The cover is an `AsyncImage(url:)` whose `.empty` phase is a
  `ProgressView`, and whose `.failure` phase is a placeholder. A spinner that stays means the
  image request never finished. The likely case is a request started while the network went
  away, waiting on a connection that is gone until its timeout, 60 seconds by default. Not
  measured.
- **Nothing asks again.** `AsyncImage` loads its URL once for as long as the view keeps its
  identity. Neither the album's reload nor a returning network touches it. A request that does
  end in `.failure` shows the placeholder for good, just the same.
- **Other covers.** The other `AsyncImage`s share this: track rows, library rows, cards, the
  now-playing bar, the artist page and the sidebar. A list opened offline shows placeholders
  or spinners until the view is rebuilt, for example by leaving the section and coming back.

## Solution

The plan's first option, one artwork view, in its smallest form: `RetryingAsyncImage`, a drop-in
for `AsyncImage(url:content:)` that every one of the nine sites now uses, their phase closures
unchanged. It starts its load again whenever the network comes back, unless its image has
arrived.

- **When the network is back** comes from `NetworkMonitor`, which iterates `NWPathMonitor` as
  the `AsyncSequence` it is and counts the path's returns to `.satisfied` after it was not. The app had no network monitor; the
  accesspoint session's reconnect was the other candidate, but it follows the session, not the
  network, and backs off.
- **Asking again** is a new identity for the `AsyncImage` (`.id(attempt)`), which drops the
  stalled or failed request and starts one. That also covers the request the plan suspected of
  waiting 60 seconds on a connection that had gone.
- **Only if the image has not arrived.** Each view follows its phase with
  `onChange(of: phase.image != nil, initial: true)`, so a return does not reload, and flash,
  every cover already on screen. An `onAppear` on the phase's content was tried first and
  dropped: the conditional content keeps its identity across phases, so it would not fire again
  when the image arrived.

The plan's other two options are not needed: the album page's Try again no longer has to retry
the cover, which retries by itself when the network returns, and a spinner that has gone on for
a while now ends when the network does come back.

**The page's own load too.** The altitude review pointed out that the repro's other half, the
track list, waited for Try again just the same. `InlineLoadError` now calls its retry on
`NetworkMonitor`'s returns as well, when it offers one, which covers the album, artist and
playlist pages, whole or a section of them. So the repro heals without a press. Other loads that
wait for a manual retry, and failures while the network stays up, are recorded in
`plans/done/failed-loads-wait-for-try-again.md`.

## Verification

- [x] Unit tests: `NetworkMonitor` counts a return only after the network was away, and counts
      coming online as one when launched offline.
- [x] A probe (a temporary test, deleted after): two `RetryingAsyncImage`s in a window, against a
      local HTTP server that answers the first request for one path with a 500 and every other
      request with a PNG, logging each. On first load each path was asked once, the first
      failing. After a network return (`NetworkMonitor.shared.update(satisfied:)` false, then
      true), only the failed one was asked again, and succeeded. After a second return, neither
      was asked again.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: turn Wi-Fi off, open an album from the library that has not been opened this session,
      turn Wi-Fi on. Within a few seconds the cover appears and the track list loads, without
      leaving the page or pressing Try again. Covers that had loaded before do not flash. Not run on
      2026-09-30: it needs Wi-Fi off. With the network on, artwork on the start page, in albums,
      playlists and search loads as before.
