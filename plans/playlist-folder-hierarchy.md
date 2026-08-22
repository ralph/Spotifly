# Playlist folders: show the hierarchy Spotify has

Status: **not started** — deferred deliberately; the flat list works and is correct
Components: `Spotifly/PartnerAPI/PathfinderLibrary.swift`, `Spotifly/PartnerAPI/PathfinderSearch.swift`,
`Spotifly/Store/Services/PlaylistService.swift`, `Spotifly/Views/PlaylistsListView.swift`,
`Spotifly/Store/AppStore.swift`, `Spotifly/Store/Entities.swift`
Recorded: 2026-08-13, splitting the "does not attempt" note out of task 12 in
`single-grant-partner-api.md`

## The flat list is not a workaround

Worth stating first, because "folders are not built" invites someone to treat the current
behaviour as broken. It is not: **every playlist is shown, including the ones inside folders.**
That is exactly what `/me/playlists` returned for the Web API's whole life, so nothing regressed
when the library moved to `libraryV3`, and nothing needs fixing to keep parity.

What is new is that Spotify's own API *has* the hierarchy and this app throws it away. The Web
API never exposed folders at all; `libraryV3` does. So this is a feature the client APIs made
possible, not a debt the migration created.

## What the API offers, measured

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

## The trap already paid for

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

## Shape of the work

1. **Measure `expandedFolders` and `folderUri` first.** One request with the whole tree and one
   request per expansion are different features; do not design before knowing which is on offer.
   Read it off the web client with DevTools rather than the probe — see
   [[measure-from-the-web-client-devtools]], which costs no re-login where `libspot-probe`
   revokes the app's grant every run.
2. **A `Folder` entity**, keyed by its full uri rather than by a bare id: the hash is not unique
   across users and is not an id in any sense the rest of the store uses.
3. **Decode folders instead of dropping them** — a kind switch on the uri where
   `PathfinderPlaylist.id` currently returns nil, with the flat behaviour still reachable.
4. **A nested sidebar section.** This is most of the work and none of the risk. Decide what
   selecting a folder does: Spotify's own clients expand it in place rather than opening a page,
   which is the cheaper answer and the one that needs no new screen.
5. **Keep the flat list as the fallback**, not as dead code: an account with no folders should
   get exactly today's rendering, and the pagination arithmetic in `PaginationState.advance` is
   written against a flat page count.

## What not to do

Do not make folders a *filter* on the existing list. The pagination is offset-based over the
list Spotify returns, so a client-side regroup of one page reorders within that page only, and
the tree changes shape as later pages arrive.
