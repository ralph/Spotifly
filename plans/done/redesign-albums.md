# Redesign: Alben

Status: **Done**, 2026-10-21, PR #213. Ninth of the stacked redesign PRs. Adding an album to a
playlist is not tried live: it is the existing `addTracksToPlaylist` with the album's tracks
Components: `Spotifly/Views/AlbumDetailView.swift`, `Spotifly/Views/LoggedInToolbars.swift`,
`Spotifly/Store/Services/AlbumService.swift`, `Spotifly/PartnerAPI/PartnerAPI.swift`,
`Spotifly/Views/Components/TrackContextMenu.swift`, `Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Playlists / Alben / Künstler"),
`design/native/Library.jsx` (`NAlbums`)

## Summary

The album list gets the handoff's sort menu (Zuletzt hinzugefügt, Titel, Künstler), sorted by
Spotify rather than over the pages loaded so far; the album page gets the detail header
("Album · Jahr", the artist as a link, tracks and duration, a Save toggle) over the track table,
and its toolbar Share and a menu.

## Problem

- The saved albums come in `libraryV3`'s default order, "Zuletzt" (recently played), and
  cannot be sorted.
- The album page centres its cover over a big green button and lists `TrackRow`s; its toolbar
  is a row of icon buttons (play next, share, go to artist, add or remove).

## Solution

### API

**The library sorts on the server.** `libraryV3` takes `order`, measured in the web player on
2026-10-21 with `filters: ["Albums"]`: the response's `availableSortOrders` are `Recents`
(the default, what `order: null` selects), `Recently Added`, `Alphabetical`, `Creator` and
`Release Date`. `Creator` sorts albums by artist, ignoring a leading "The" (AM Taxi, The
Avener, Beady Eye, The Beatles). Sorting on the server keeps the order right across pages,
which a sort of the loaded pages would not be.

- `PartnerAPI.libraryAlbums(offset:order:)` sends it.
- `AlbumSort` (`recentlyAdded`, `title`, `artist` → `Recently Added`, `Alphabetical`,
  `Creator`). `AlbumService.sort`, kept in `UserDefaults` as recent searches are; changing it
  reloads the list from the first page.

Adding an album to a playlist is the existing `addTracksToPlaylist` with the album's tracks.

### List

- Toolbar, leading in the Alben section (a `.navigation` item of its own): `Picker(.menu)` with
  the three sorts.

### Album page

- `DetailHeader`: 132 pt cover, "Album · 1994", the name, then the artist (a link to the
  artist when the album names one), "N Titel", the duration; Abspielen, Zufällig, and a bordered
  toggle "In Bibliothek" / "Zur Bibliothek" (removal keeps its confirmation).
- `TrackTable` with #, Titel, Dauer, not sortable: an album is read in its order.
- Toolbar: Share, and a `Menu` with Abspielen, Als Nächstes spielen, Zu Playlist hinzufügen
  (the playlist submenu the track menu has), then Zum Künstler, Link kopieren.

## Verification

- Build, unit tests.
- Run the Debug build: sort the list three ways, open an album, play it from a row, remove and
  re-add a saved album (it returns to the library), add an album to a test playlist (then
  delete that playlist), Share, Zum Künstler.

### Result

- Live: the list in Recently Added order (Not Bad for New Jersey, Alive, Dookie, Anthology 4,
  as the web player has it), then by Artist (AM Taxi, The Avener, Beady Eye, The Beatles); the
  header, the table and the toolbar as the handoff draws them; an unsaved album
  ("Sleepwalkers", from search) saved with the toggle, listed under Brian Fallon in the Artist
  order, and removed again, the page staying with the toggle back at "Zur Bibliothek".
- A saved album goes first in the list whatever the sort, until the list is read again. Reading
  the list again right after the save, which `/code-review` suggested, was tried and reverted
  on Codex's finding: the reload replaces the saved ids with the first page, so an album sorted
  past it read as unsaved. Membership derived from a paged list is the deeper issue, and an
  older one: a saved album beyond the loaded pages, opened from search, offers "Zur Bibliothek"
  too.
- `/simplify`: one Share-and-menu builder for albums and playlists, `Artwork.detailHeader`,
  the sort menu from `AlbumSort`'s cases, the album removal notification nothing posts removed.
