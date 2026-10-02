# A start page refresh takes the owner's actions off an owned playlist

Status: **Done** 2026-10-02, and verified live: an owned playlist on the start page keeps its owner's
actions through a refresh. Found in the altitude review of the share fix.
Components: `Spotifly/PartnerAPI/PathfinderEntities.swift` (`Playlist(pathfinder:)`, the start
page's stubs), `Spotifly/PartnerAPI/PathfinderSearch.swift` (`PathfinderPlaylist.Owner`),
`Spotifly/Store/AppStore.swift` (`upsertPlaylist`), `Spotifly/Store/Entities.swift`
Found: 2026-10-02, in `/simplify` of `plans/done/share-greyed-everywhere.md`

## Summary

A playlist's owner decides the owner-only actions: Edit Details, the cover menu and Delete in the
toolbar, and "Add to Playlist". Every playlist the start page delivered had no owner, and storing
it replaced the owner a playlist's own load had found. An owned playlist on the start page lost
those actions on every refresh of it (⌘R, or pull to refresh), until the app was relaunched.

## Problem

- **Measured on 2026-10-02**, with a throwaway log of the playlists the start page delivered:
  - all 114 distinct playlists had `ownerId` empty;
  - the answer names a playlist's owner by uri only, `ownerV2.data.uri` `spotify:user:<id>`,
    with `username` null. `Playlist(pathfinder:)` read only `username`.
  - The start page's trait entries (Recents) built their stub with `ownerId: ""`, though their
    contributor carries the same uri (the recorded page in `PathfinderHomeTests` has one of the
    user's own playlists, "relink-test", that way).
- **Storing it:** `AppStore.upsertPlaylist` keeps a summary's items, and nothing else, so the
  empty owner replaced the real one. The playlist's tracks were loaded, so nothing loaded it again.
- The code expected the owner from the playlist's own load ("the playlist detail load supplies
  the id when it is needed"), and the next summary undid it.

## Solution

- **Read the owner where it is:** `PathfinderPlaylist.Owner` decodes the owner's `uri`.
  `Playlist(pathfinder:)` takes the username, or else the id in that uri. The start page's stubs
  take it from their contributor's uri.
- **Keep a known owner and description:** `upsertPlaylist` keeps what a load found when a summary
  names no owner or no description. A Recents entry carries neither.
  - A playlist's owner never changes, so the kept owner is never stale.
  - The description matters as soon as the owner is back. Before, a refresh blanked the description
    and hid Edit Details. With the owner restored, Edit Details would open on the blank and save it
    over the real description on Spotify.
  - A description cleared on another device stays here until the playlist is loaded again, which is
    the lesser cost.

### Left

The owner also gates adding and removing tracks (`TrackContextMenu`), where a collaborator may edit
too. Whether a playlist's own load says so per user isn't measured.

## Verification

- **Unit tests:**
  - a start page playlist names its owner, from a recents contributor and from `ownerV2`'s uri;
  - a summary with no owner or description keeps the stored ones.
- **Live, 2026-10-02:** with the fix, the start page's playlists named their owners: `spotify`
  for Spotify's, `ericpuig` for "Good Vibrations OST", and a user id for "Mein Lotta-Leben".
- **Live, the toolbar, 2026-10-02:** an owned test playlist on the start page's "Recently played",
  opened from there:
  - main: Edit Details, the cover menu and Delete were gone after one ⌘R, replaced by the button
    that removes someone else's playlist from the library;
  - with the fix: all three stayed through three ⌘R, and Edit Details still held the description.
- **Getting an owned playlist onto Recents:** Spotifly sends no play events, so playing it there
  doesn't do it. A double-click on its row in the web player did, though playback sat at 0:00
  there: Spotifly's start page had it at the next launch, a minute later. Another owned playlist
  the web player had only loaded, "relink-test abc yo", was on it too.
