# Redesign: Favoriten, and the detail header and track table every list shares

Status: **Done**, 2026-10-21, PR #211. Seventh of the stacked redesign PRs. Zufällig's shuffle after
the play is not seen against a radio live
Components: `Spotifly/Views/FavoritesListView.swift`, `Spotifly/Views/Components/DetailHeader.swift` (new),
`Spotifly/Views/Components/TrackTable.swift` (new), `Spotifly/Store/Services/TrackService.swift`,
`Spotifly/Store/AppStore.swift`, `Spotifly/ViewModels/PlaybackViewModel.swift`, `Spotifly/Views/LoggedInView.swift`,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Favoriten", "Interactions"),
`design/native/Library.jsx` (`DetailHeader`, `NFavorites`), `design/native/Screens.jsx` (`TrackTable`)

## Summary

Favoriten gets the handoff's detail header (132 pt art, "Playlist", the title, "N Titel ·
Dauer", Abspielen and Zufällig) over a sortable `Table` with #, Titel, Album, Hinzugefügt and
Dauer, a heart and a menu per row. The header and the table are components the queue, playlist
and album pages take over in the PRs after this one.

## Problem

Favorites are a hand-built list of `TrackRow`s with no header, no way to sort, no album column
and no date added, and no Play or Shuffle for the whole list.

## Solution

### API

- **Hinzugefügt:** Liked Songs is read as the playlist `LikedSongs.uri` through
  `fetchPlaylistContents`, whose items carry `addedAt.isoString` beside the track; it is decoded
  (`PathfinderPlaylistItem.addedAt`) and not read. `TrackService.loadFavorites` keeps it per track
  in `AppStore.favoriteAddedAt`.
- **Abspielen:** `PlaybackViewModel.play(uriOrUrl: LikedSongs.uri)`, as a double-click does.
- **Zufällig:** play from a random track, then set shuffle on. `PlaybackQueue.setContext` keeps
  shuffle across a new context and shuffles around the starting row; after the play, because a
  radio playing before refuses shuffle (Codex). (The web player's playlist shuffle
  toggle sends nothing to the device; measured 2026-10-21.)
- Sorting needs every row, so the page loads all of Liked Songs' pages (50 a page) rather than
  one on scrolling.

### Components

- `DetailHeader`: art, kind label (`.subheadline` semibold, secondary), title (30 pt bold),
  one metadata line, and a row of actions; it stacks vertically under 520 pt.
- `TrackTable`: a SwiftUI `Table` with `sortOrder` over rows the caller builds, columns chosen per
  page (#, Titel with a 32 pt cover over artist, Album, Hinzugefügt, Dauer, actions). A click
  selects, a double-click (`contextMenu(forSelectionType:primaryAction:)`) plays, a right click
  opens the track menu (`TrackContextMenu`). The playing row is accent-coloured and its number is
  an animated `waveform`. Unplayable rows dim, as everywhere.

### Favoriten

`DetailHeader` (heart on a red gradient) over `TrackTable` with all five columns; Refresh in the
toolbar as today. On Favoriten the toolbar's search field filters the list, with the prompt
"In Favoriten suchen", and Return does not search Spotify.

## Verification

- Build, unit tests.
- Run the Debug build: screenshot Favoriten; sort by Titel, Hinzugefügt, Dauer; filter; double-
  click a row; Abspielen and Zufällig (then pause); narrow the window under 520 pt.

### Result

- Live: the header and table as the handoff draws them, all 323 favorites with their dates,
  sorting by Dauer, the filter, a double-click playing from the row, Refresh reloading all
  pages, light and dark.
- **A table cell lost its environment.** A cell built after a later page loaded found no
  `PlaybackViewModel` and trapped (`.ips` 2026-10-21 18:23); the table hands its cells the
  objects they read. The bar covered the last rows: no content margin reaches a table, so it
  takes a bottom inset, as Playing On's form does.
- Reviews: `/simplify` made the cells follow the playing track themselves (the table no longer
  redraws on every playback change), batched the hearts' status check, and moved "load all" into
  `TrackService`. Codex found six more, fixed: refresh stranded the list at its first page, a
  failed page was invisible, shuffle before the play was refused by a radio, a search's query
  filtered Favorites on opening, paging stopped on a page of duplicates, and dates added did not
  follow saving and unsaving.
