# The toolbar's refresh moves the selection when it lies past the first page

Status: **Open**, not planned. Same on `main`, so not caused by
`plans/open/state-held-twice.md`
Components: `Spotifly/Views/LoggedInView.swift` (`refreshAction(for:)`),
`Spotifly/ViewModels/NavigationCoordinator.swift` (`restoredSelection`)
Found: 2026-10-02, in the review of that plan's phase 4

## Summary

After the toolbar's refresh in Playlists, Albums or Artists, `refreshAction(for:)` restores the
selection against the first page only. A selection that is not on it jumps to the list's first
row.

## Problem

A forced load fetches one page of 50. `restoredSelection(previous:available:)` keeps the
previous selection only if that page holds it. So the selection moves in two cases:
- a playlist, album or artist further down the library;
- an entity shown ephemerally, opened from search or an artist page.

Pull-to-refresh and Try again make the same load without the restore, and keep the selection.

## Solution

Not planned. Probably drop the restore. The coordinator's ephemeral model already shows a
selection that is not in the list. An entity removed upstream could instead be handled the way
`deletedEntitySelections` invalidates routes, which would serve every refresh path.

## Verification

None yet.
