# Redesign: Warteschlange

Status: **Done**, 2026-10-21, PR #215. Eleventh of the stacked redesign PRs
Components: `Spotifly/Views/QueueListView.swift`, `Spotifly/Views/Components/TrackTable.swift`,
`Spotifly/*.lproj/Localizable.strings`, `Spotifly/*.lproj/Localizable.stringsdict`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Warteschlange"),
`design/native/Screens.jsx` (`NQueue`)

## Summary

The queue becomes the track table the other pages use, under a large "Warteschlange" title with
"N Titel · M ausstehend".

## Problem

The queue lists `TrackRow`s under a small material header, the one list left that is not the
redesign's table.

## Solution

### API

Nothing new: the rows are `PlayerModel.queueEntries`, as now, and a double-click plays a row
through `PlaybackViewModel.play(queueRow:)`.

**What the handoff asks for and the app has not got.** Its toolbar has "Alle in den
Offline-Cache laden" and its rows a "C" tag for a track in the offline cache. The app keeps no
offline cache (nothing in `SwiftLibrespot` writes audio to disk), so neither is built. The
handoff's "C" reads as the tag the queue already shows, the row's provider: Q for a track
queued by hand, C for one from the context, A for autoplay. That tag stays, now in the table.
The queue stays read-only plus append, as the handoff says.

### Page

- Header: "Warteschlange" in the large title style, then "N Titel · M ausstehend", then, as now,
  "Wird abgespielt von „X“ auf Y" with the context as a link.
- `TrackTable` with #, Titel, Dauer, not sortable: the numbers run over the whole queue, rows
  already played are dimmed, as `TrackRow` dimmed them, and each row carries its provider tag.
- The toolbar keeps Refresh and "Zum aktuellen Titel scrollen"; the table scrolls to the
  current row (`ScrollViewReader` on the table's row ids).
- `TrackTableRow` gains `isDimmed` (played, or a row the player could not name) and `tag`, which
  only the queue sets, and `isPlaying(currentRowId:playingUri:)`: the queue names its current row,
  so a track queued twice lights one row, the rule `TrackRow.isCurrent` held. Rows are named by
  uid, so a skip shifts no ids.

## Verification

- Build, unit tests.
- Run the Debug build with something queued: the counts, the tags, the dimmed rows, the
  current row in the accent colour, a double-click on a next row (then pause), scroll to
  current.

### Result

- Live: "Warteschlange", "34 Tracks · 33 ausstehend", every row tagged C (a Green Day artist
  context); scrolling down and "Zum aktuellen Titel scrollen" brought the playing row back; a
  double-click on "Basket Case" played it, the row before dimmed, paused at once.
- `/simplify` caught a regression the move to the table made: the table matched the playing
  track by uri, so a track queued twice lit both rows. The position rule moved to
  `TrackTableRow.isPlaying`, and with it scroll-to-current into the table. Also: ids by uid,
  the header as a view of its own (a device's volume no longer redraws the table), the hearts
  checked when the rows change rather than their count, `TrackRow` down to what search uses,
  and one `metadataLine` for the four pages that joined it by hand.
- `/code-review`: a context repeating wraps into the next tracks with uids already listed;
  such a row gets an id of its own. Codex found nothing further.
