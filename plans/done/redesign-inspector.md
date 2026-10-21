# Redesign: the "Jetzt läuft" inspector

Status: **Done**, 2026-10-21, PR #207. Third of the stacked redesign PRs
Components: `Spotifly/Views/NowPlayingInspector.swift` (new), `Spotifly/Views/LoggedInView.swift`,
`Spotifly/Views/NowPlayingBarView.swift`, `Spotifly/WindowState.swift`, `Spotifly/SpotiflyApp.swift`,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Inspector "Jetzt läuft"", "Player bar")

## Summary

A 320 pt `.inspector` on the right of the window shows what is playing — 280 pt artwork, title,
artist, album — and "Als Nächstes", the next eight tracks, each of which plays on a click. The
bar's last button and ⌥⌘I show and hide it.

## Problem

The app has no now-playing view beyond the bar: a bigger cover and what comes next are only on
the Queue page, which replaces whatever the window was showing.

## Solution

### API

Nothing new. The track is `PlaybackViewModel.currentTrack` (title, artist, album name, images).
"Als Nächstes" is `PlayerModel.queueEntries.nextTracks`, whose metadata `QueueService` already
loads into the store on every queue change; the header's count is `nextTracks.count`, as the
sidebar badge's. A click plays the row through `PlaybackViewModel.play(queueRow: .next(…))`,
the same call as a double-click in the Queue page, so another device gets the web player's
`skip_next` to that row.

### View

- `NowPlayingInspector`: a header "Jetzt läuft"; the cover at up to 280 pt (`Artwork`, 10 pt
  corners); title (`.title2.bold`), "artist", album name in tertiary; a divider; "Als Nächstes"
  with "N Titel" on the right; a `List` of up to eight rows: 32 pt cover (4 pt corners), title
  over artist, duration. Rows the store has no metadata for yet are skipped, as the Queue page
  skips them. Nothing playing shows a `ContentUnavailableView`.
- `LoggedInView` attaches `.inspector(isPresented:)` to the split view with
  `.inspectorColumnWidth(320)`.
- Visibility lives in `WindowState.isInspectorPresented`, beside the mini player's flag: the
  bar's button and the View menu's "Jetzt läuft" (⌥⌘I) both flip it. The mini player shows no
  inspector.
- The bar's trailing group ends with the toggle (`sidebar.right`, accent while shown).

## Verification

- Build, unit tests.
- Run the Debug build, open the inspector from the bar and with ⌥⌘I, screenshot it while a
  track plays; click an "Als Nächstes" row and see that track play; hide it again.

### Result

- Live: View → Jetzt läuft and the bar's toggle show it; a click on "Pearls" in Als Nächstes
  took the mirrored track over and played Pearls, as a queue row does. Screenshots matched the
  handoff once the inspector drew an opaque background (its default glass let the page's covers
  bleed through) and a header of its own (`.navigationTitle` shows none in an inspector).
- Reviews: `/simplify` moved the next rows into `Queue.nextRows(in:)`, shared with the Queue
  page, keyed the rows by uid so covers survive the queue advancing, and swapped the `List` for
  a plain stack. `/code-review` found unplayable tracks undimmed; Codex then found that a click
  on one still skipped to it. Both fixed as `TrackRow` does it.
