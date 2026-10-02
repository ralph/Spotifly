# The toolbar's refresh moves the selection when it lies past the first page

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/Views/LoggedInView.swift` (`refreshAction(for:)`),
`Spotifly/ViewModels/NavigationCoordinator.swift` (the restore helpers, removed)
Found: 2026-10-02, in the review of `plans/done/state-held-twice.md`, phase 4

## Summary

After the toolbar's refresh in Playlists, Albums or Artists, `refreshAction(for:)` restored the
selection against the first page only, so a selection that was not on it jumped to the list's
first row. The refresh now makes the same load as pull-to-refresh and Try again, and leaves the
selection alone.

## Problem

A forced load fetches one page of 50. `restoredSelection(previous:available:)` kept the previous
selection only if that page held it. So the selection moved in two cases:
- a playlist, album or artist further down the library;
- an entity shown ephemerally, opened from search, an artist page or the start page.

Pull-to-refresh and Try again make the same load without the restore, and kept the selection.

## Solution

The three closures in `refreshAction(for:)` only call the service's
`load…(forceRefresh: true)`. `NavigationCoordinator.restorePlaylistSelection`,
`restoreAlbumSelection`, `restoreArtistSelection` and `restoredSelection` had no other caller and
are gone.

Nothing else was needed:
- **A selection not in the list** is shown as the section's ephemeral entry ("Currently
  viewing"), as after any other load.
- **No selection** is filled by `LibraryListView`, whose `.onChange(of: items)` selects the first
  row when nothing is selected.

An entity removed upstream, such as an album unsaved on the phone, now stays selected after a
refresh and is listed as the ephemeral entry, where the restore moved to the first row. The page
still exists and shows the same thing as before the refresh, so that is the same as every other
load, not a regression; nothing invalidates it the way `deletedEntitySelections` does a playlist
deleted in this app.

## Verification

### Live (2026-10-02)

`SPOTIFLY_DEBUG_OPEN=spotify:album:0ETFjACtuP2ADo6LFhL6HN` opened Abbey Road, which is not in the
account's albums, so Albums listed it under "Aktuelle Ansicht" above the library. Then the
toolbar's Aktualisieren, pressed through accessibility; the log shows the second `libraryV3`.

- **Before (main, `082d005`):** the selection jumped to the first album, "Saviors (édition de
  luxe)", whose page opened, and the "Aktuelle Ansicht" entry was gone.
- **After:** Abbey Road stays selected and its page stays open, still listed as the ephemeral
  entry.

The account has fewer than 50 saved albums (one `libraryV3` request, no second page), so the
first case, a selection past the first page, was not reproduced; it takes the same path.

### Unit tests

588 pass. No test covered the restore, which lived in the view.
