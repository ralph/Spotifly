# Playlist folders: show the hierarchy Spotify has

Status: **Done** 2026-09-29. The variables measured from the web player's session; built,
unit-tested, and the section rendered in the test host; not yet seen in the running app; see
Verification.
Components: `Spotifly/PartnerAPI/PathfinderLibrary.swift` (`depth`), `Spotifly/PartnerAPI/PathfinderSearch.swift`
(`PathfinderPlaylist.folderUri`), `Spotifly/PartnerAPI/PartnerAPI.swift` (`libraryPlaylistOutline`),
`Spotifly/Store/Services/PlaylistService.swift` (`loadPlaylistOutline`), `Spotifly/Store/AppStore.swift`
(`playlistOutline`), `Spotifly/Store/Entities.swift` (`PlaylistOutlineRow`),
`Spotifly/Views/LibraryListView.swift` (`LibraryOutlineRow`), `Spotifly/Views/PlaylistsListView.swift`,
`Spotifly/Views/LoggedInView.swift` (the refresh)
Found: 2026-08-13, splitting the "does not attempt" note out of task 12 in
`plans/done/single-grant-partner-api.md`

## Summary

The Playlists section is a flat list. Spotify's `libraryV3` has the folder hierarchy, and
Spotifly drops it. Nothing is broken, because every playlist is shown, including those inside
folders. Showing the tree is a feature the client APIs made possible, not a debt.

## Problem

### The flat list is not a workaround

Worth stating first, because "folders are not built" invites someone to treat the current
behaviour as broken. It is not: **every playlist is shown, including the ones inside folders.**
That is exactly what `/me/playlists` returned for the Web API's whole life, so nothing regressed
when the library moved to `libraryV3`, and nothing needs fixing to keep parity.

What is new is that Spotify's own API *has* the hierarchy and this app throws it away. The Web
API never exposed folders at all; `libraryV3` does. So this is a feature the client APIs made
possible, not a debt the migration created.

### What the API offers, measured

Two variables decide it, measured 2026-08-13 against an account with four folders
(`PathfinderLibraryVariables`):

| `flatten` | `includeFoldersWhenFlattening` | result |
| --- | --- | --- |
| `false` | either | 14 items: 10 playlists and 4 folders, folder contents hidden |
| `true` | `true` | 38 items: 34 playlists and 4 folders |
| `true` | `false` | **34 items: every playlist, no folders** — what the app sends |

Two more variables exist and are currently sent as their empty defaults: `expandedFolders:
[String]` and `folderUri: String?`. Their names say what they are for, and **neither has been
exercised** — nobody here has sent a folder uri or a non-empty expanded list and looked at the
answer. That is the first thing to measure, and the cheapest: it decides whether the hierarchy
arrives in one request or one request per open folder.

### The trap already paid for

**A folder decodes cleanly as a playlist.** It carries a `uri` and a `name` and nothing in the
shape distinguishes it, so the only thing that tells them apart is the uri's kind:
a folder is `spotify:user:<user>:folder:<hash>`, where a playlist is `spotify:playlist:<id>`.

Taking the last component of a uri returns the hash and yields a folder that looks like a
playlist with a plausible id — it renders as a row and answers "Spotify returned no data" when
opened. `SpotifyURI.id(from:kind:)` exists because of this, and `PathfinderPlaylist.id` is
kind-checked where the other entities are not.

**That guard is what currently drops folders**, silently and by design. Anyone building this
feature has to stop relying on it as a filter and start treating a folder as its own kind —
which means the change is not additive: removing the drop without adding a `Folder` entity puts
the broken rows straight back.

## Solution

### What was measured

2026-09-29, from the web player's session in Chrome, the app's own `libraryV3` query and hash,
recording counts and kinds only. The account had 38 playlists and 4 folders, none nested:

| Variables | Answer |
|---|---|
| `flatten: false` | 18 entries: 14 playlists and 4 folders, all at `depth` 0, the folders closed |
| `flatten: false`, `folderUri: <a folder>` | 2 entries: that folder's playlists |
| `flatten: false`, `expandedFolders: [<a folder>]` | 20: the top level, that folder's 2 playlists after it at `depth` 1 |
| `flatten: false`, `expandedFolders: [<all four>]` | **42: the whole tree in order, each folder followed by what it holds at `depth` 1** |
| the same, `offset: 10, limit: 10` | the same sequence from its eleventh entry |
| `flatten: true`, `includeFoldersWhenFlattening: true` | 42, but the 4 folders together in the middle and every entry at `depth` 0 |

A folder is `__typename: "Folder"`, `{name, uri, playlistCount, folderCount}`, in a
`LibraryFolderResponseWrapper`; every entry carries its `depth`. So the plan's first question
has its answer: the hierarchy arrives in **one** offset-paged list once every folder is named in
`expandedFolders`, and the flattened list, folders included or not, cannot carry it.

### What changed

- **The flat list stays what everything else reads.** `loadUserPlaylists` is unchanged:
  flattened, without folders, every playlist, which the add-to-playlist menus and the section's
  selection need, whatever is open.
- **The outline is loaded beside it**, for the section alone, by
  `PlaylistService.loadPlaylistOutline`: the top level unflattened, then again with the folders
  it found named in `expandedFolders`, and again while a pass finds folders not named yet, which
  only a folder inside a folder shows; six passes at most. An account with no folders costs the
  one request. Each entry becomes a `PlaylistOutlineRow`, a folder keyed by its full uri or a
  playlist by its id, with its depth (`PathfinderLibraryItem.depth`,
  `PathfinderPlaylist.folderUri`). The playlists are upserted as they come.
- **The section shows it when there are folders.** `LibraryListView` takes an optional outline
  of `LibraryOutlineRow`s and shows it instead of its flat rows: a folder as a row with a folder
  glyph and a chevron, closed until clicked, what it holds indented under it. Which folders are
  open is kept in `@AppStorage`, across launches, as Spotify's clients keep theirs. Without
  folders there is no outline, and the section is exactly the flat list it was, the plan's
  fallback.
- **The flat list says what is in the library.** The outline is loaded once, and every change
  made here goes to the flat list, so `PlaylistsListView.outline` shows the outline's rows for
  the playlists the flat list holds: a playlist created or followed since goes at the top, where
  the flat list puts it, and one deleted or unfollowed since is left out. Refresh loads both
  again.

Selecting a folder expands it in place, the plan's cheaper answer: no folder page. The trap the
plan named stays shut: `PathfinderPlaylist.id` still refuses a folder's uri, so no folder becomes
a playlist row.

## Verification

- [x] Measured, as above.
- [x] Unit tests: a first pass that finds a folder is followed by one that names it, and the
      outline has the folder's playlist at depth 1; an account with no folders costs one request
      and has no outline; the section's outline takes a playlist created since at the top and
      leaves out one deleted since.
- [x] Rendered in the test host (a temporary test, deleted after): a playlist at the top, the
      selected one, an open folder with its playlist indented under it and the chevron down, a
      closed folder with its playlist hidden and the chevron right, and a last playlist.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: the Playlists section shows the account's folders, closed. Opening one shows its
      playlists indented; it stays open after a relaunch. Selecting a playlist in a folder opens
      it as any other.
- [ ] Live: a new playlist appears at the top; a deleted one disappears. Refresh keeps the
      folders.
- [ ] Live, an account or a check with no folders: the section looks as it did.
