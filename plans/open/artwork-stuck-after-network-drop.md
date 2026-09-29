# Artwork that did not load keeps spinning after the network is back

Status: **Open**, not planned. Seen 2026-09-29 while testing #82. The cause below is read from
the code; the request's own fate (stalled or failed) was not logged.
Components: every `AsyncImage` in `Spotifly/Views`: `AlbumDetailView`, `ArtistDetailView`
(twice), `PlaylistDetailView`, `LibraryListView`, `TrackRow`, `NowPlayingBarView`,
`Components/CardArtwork.swift`, `SidebarView`
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

Not planned. Options:

- **One artwork view.** A small view to replace the eight `AsyncImage`s, which retries on
  failure, and again when the network returns (`NWPathMonitor`, or the app's own connection
  state). It shows the placeholder rather than a spinner once a request has taken long.
- **A cheaper fix for detail pages.** Key the header's image on a reload counter, with
  `.id(url, reloadCount)`, and bump it from the page's Try again, so retrying the page
  retries its cover too.
- **Timing.** A spinner that runs past a few seconds could fall back to the placeholder,
  whatever the request is doing.

## Verification

Not planned. To reproduce: turn Wi-Fi off, open an album from the library that has not been
opened this session, turn Wi-Fi on, and press Try again. After the fix, the cover appears
once the network is back, without leaving the page.
