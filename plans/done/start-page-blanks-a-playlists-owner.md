# A start page refresh takes the owner's actions off an owned playlist

Status: **Done** 2026-10-02 in code, and measured: the start page's playlists now name their owners.
Not seen live: the toolbar of an owned playlist that is on the start page, since none was on it
during the session; see Verification. Found in the altitude review of the share fix.
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
- **Keep a known owner:** `upsertPlaylist` keeps the owner a load found when a summary names none.
  A playlist's owner never changes, so this is never stale. It covers any other summary without
  one.

## Verification

- **Unit tests:**
  - a start page playlist names its owner, from a recents contributor and from `ownerV2`'s uri;
  - a summary with no owner keeps the stored one, loaded or not.
- **Live, 2026-10-02:** with the fix, the start page's playlists named their owners: `spotify`
  for Spotify's, `ericpuig` for "Good Vibrations OST", and a user id for "Mein Lotta-Leben".
- **Not seen live:** an owned playlist on the start page keeping its toolbar through a refresh.
  None was on the page: Spotifly sends no play events, so playing one there didn't add it to
  Recents, and the web player wouldn't start playing by itself.
