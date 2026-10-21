# Redesign: Playlists, and the library column Alben and Künstler share

Status: **Done**, 2026-10-21, PR #212. Eighth of the stacked redesign PRs. Dragging a row to
reorder is not tried live: the move's service calls are unchanged, its table plumbing is new
Components: `Spotifly/Views/LibraryListView.swift`, `Spotifly/Views/PlaylistDetailView.swift`,
`Spotifly/Views/LoggedInView.swift`, `Spotifly/Views/LoggedInToolbars.swift`, `Spotifly/Store/Entities.swift`,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Playlists / Alben / Künstler"),
`design/native/Library.jsx` (`SplitList`, `NPlaylists`)

## Summary

The library's middle column gets its own filter field, rows with a second line and the
handoff's 200–300 pt width; the playlist page gets the detail header and the track table from
Favoriten, a follow toggle for other people's playlists, and the toolbar's New playlist, Share
and a menu.

## Problem

- The middle column lists names only, has no way to filter, and runs 280–560 pt wide.
- The playlist page centres a 200 pt cover over a big green button and lists `TrackRow`s; its
  toolbar is a row of six icon buttons (play next, share, edit, cover, delete or follow).

## Solution

### API

Nothing new. Playlists, their items with uids, owners and follow state are loaded as today;
New playlist is `PlaylistService.createPlaylist`, follow/unfollow, edit, cover, delete and move
are the existing calls.

**Other people's playlists keep their track list.** The handoff replaces it with "Titelliste
nicht verfügbar" because the Web API stopped returning items for playlists one does not own or
collaborate on (Feb 2026). The app reads playlists through pathfinder's `fetchPlaylistContents`,
which returns them, so the table stays; the follow toggle the handoff adds is kept.

### Library column (`LibraryListView`, all three sections)

- A search-style `TextField` at the top, "Playlists filtern" / "Alben filtern" / "Künstler
  filtern", filtering the loaded entries by name and subtitle; "Keine Treffer" when nothing
  matches.
- Rows: 36 pt cover (round for artists), name over a secondary subtitle — "N Titel" or "von …"
  for a playlist, the artist for an album, none for an artist.
- `LoggedInView`'s split: the column is 200–300 pt, ideal 260.

### Playlist page

- `DetailHeader`: 132 pt cover, "Playlist" (or "Playlist · Gefolgt"), the name, the
  description, "von Owner · N Titel · Dauer", Abspielen, Zufällig, and for someone else's
  playlist a bordered toggle "In Bibliothek" / "Zur Bibliothek".
- `TrackTable` with #, Titel, Album, Dauer, sortable; own playlists keep drag-to-reorder while
  the table is in the playlist's order (`TableRow.draggable` and `onInsert` on the rows; `dropDestination` takes no index there).
- Toolbar: New playlist (leading), Share, and a `Menu` with Abspielen, Zur Warteschlange
  hinzufügen, then Details bearbeiten…, Cover…, Playlist löschen… for one's own, or Aus/Zur
  Bibliothek for another's, then Link kopieren.

## Verification

- Build, unit tests.
- Run the Debug build: filter the column, open own and followed playlists, sort, reorder a
  track in a test playlist created for it (then delete that playlist), follow/unfollow a
  playlist and restore it, New playlist (and delete it again), Share.

### Result

- Live: the column filters ("Sauna"), rows show their owner; an own playlist and someone else's
  ("Sommer", "Playlist · Gefolgt", 64 tracks listed, "In Bibliothek") render as the handoff
  draws them; the toolbar's New Playlist made "Spotifly-redesign-test", which opened, and the
  menu's "Playlist löschen" deleted it again.
- Reviews: `/simplify` had the playlist's rows built once per redraw again (a regression of
  `playlist-rows-built-once-per-row`) and the filter computed once. Codex found three, fixed: a
  failure over a non-empty playlist was hidden, a column sorted back by # stayed unmovable, and
  New Playlist needed a selection.
