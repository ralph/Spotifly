# Owner-only actions depend on the launch's profile request

Status: **Open**, not planned
Components: `Spotifly/Views/Components/TrackContextMenu.swift`,
`Spotifly/Views/PlaylistDetailView.swift`, `Spotifly/Views/LoggedInToolbars.swift`,
`Spotifly/Store/Services/ProfileService.swift`
Found: 2026-10-02, in the review of `plans/open/state-held-twice.md`, phase 4

## Summary

Whether a playlist is the user's is decided by comparing its `ownerId` with `store.userId`,
read synchronously. Only the launch and the network's return fetch the profile for that.

## Problem

These read `store.userId` without asking `ProfileService`:
- `TrackContextMenu` (Remove from this playlist, and the owned playlists under Add to playlist);
- `PlaylistDetailView` (owner-only actions);
- `LoggedInToolbars` (Edit Details, cover, Delete).

A launch request that fails while the network is up is not retried. The network-return retry
only fires on a return. So until a relaunch, the owner-only actions are missing and Add to
playlist offers no playlists. A playlist write itself still works, because it fetches the
profile through `ProfileService.require()`.

## Solution

Not planned. Possibly `ProfileService` keeps the profile loaded as a session job, retrying a
failure that was not a network failure, instead of only fetching it on demand for writes.

## Verification

None yet.
