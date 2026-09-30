# Playlist attributes Spotifly cannot write

Status: **Open**, planned as far as the requests go and deliberately not built: no screen asks
for any of the three. The web client's bundle read on 2026-09-29, which settled what each would
take; see Solution.
Components: `Spotifly/PartnerAPI/PlaylistChanges.swift`, `Spotifly/PartnerAPI/SpclientAPI.swift`,
`Spotifly/Store/Services/PlaylistService.swift`
Found: 2026-08-13, splitting the "not built" note out of task 12c in
`plans/done/single-grant-partner-api.md`

## Summary

Spotifly writes a playlist's name and description. It cannot set its cover image, whether it
is collaborative, or `pl3_version`. Reading is complete: cover art shows everywhere it should.

## Problem

### What is missing, and what is not

**Reading is complete. This is only about writing.** Playlist cover art displays everywhere it
should: `PathfinderPlaylist.images` decodes it, `Playlist.images` holds it as an `ImageSet`, and
the views render it. Nothing on the read path is outstanding, and it is worth saying plainly
because "playlist images" in a list of gaps reads like they are broken.

What Spotifly cannot do is *set* three things on a playlist:

| Attribute | State |
| --- | --- |
| `name` | written — `PlaylistOp.attributes(name:description:)` |
| `description` | written — same call |
| cover image | not written, and **not part of the attributes message at all** |
| `collaborative` | not written |
| `pl3_version` | not written |

`PlaylistOp.Attributes` models exactly two fields on purpose:

```swift
struct Attributes: Encodable, Sendable {
    var name: String?
    var description: String?
}
```

The upstream `playlist4_external` `ListAttributes` message carries more than two. Modelling only
what the app sets keeps `ListAttributesPartialState`'s partial semantics honest — a nil field is
omitted and the existing value stands, so every field the struct names is a field a rename could
overwrite with nothing if a caller forgets it.

### Why it is not a defect

There is no screen for any of the three. Nothing in the app offers to change a playlist's cover,
make one collaborative, or touch a version field, so there is no button wired to a call that
silently does nothing. The risk this file exists to prevent is the opposite one: someone reading
`changePlaylistAttributes` and assuming the write path covers the rest of the attributes,
then building a UI on top of it.

## Solution

### What the web client does, read from its bundle

Read on 2026-09-29 from the web player's scripts (`web-player.*.js`), with nothing sent: the code
that builds these requests, not a capture of one being made. Watching one would have meant
changing a playlist of the account.

- **The message carries all three.** The client's own `ListAttributes` decoder names `name`,
  `description`, `picture` (field 3, bytes), `collaborative` (field 4), `pl3Version`,
  `deletedByOwner`, `clientId`, `format`, `formatAttributes`, `pictureSize` and more. So they
  are fields of the message this app already sends in `UPDATE_LIST_ATTRIBUTES`.
- **It never writes `collaborative`.** Nothing in the bundle sets it; it appears only in the
  decoder's defaults (`collaborative: false`). Collaboration in the current client is "Invite
  collaborators" (`inviteCollaboratorsButton` in its context menu), which goes to a separate
  service, `playlist-permission/v1`, with invitations rather than a flag.
- **Nor `pl3_version`**, outside the same defaults.
- **The cover is three requests, all `POST`:**
  1. the image to `image-upload.spotify.com`, endpoint `image-upload/v4/playlist`, as
     `Content-Type: image/jpeg`, which answers with an `uploadToken`;
  2. `{uploadToken}` to `playlist/{id}/register-image`, which answers with the image's id as
     `picture`;
  3. that id as `picture` in an `UPDATE_LIST_ATTRIBUTES` change to `playlist/{id}/changes`, the
     request `changePlaylistAttributes` already sends for a rename.

  Size limits, and the headers the upload host wants, are not in what was read.

### What each would take now

- **`collaborative`: not as an attribute.** Setting the flag is what the Web API once did and the
  current client does not, so building it would copy a path Spotify's own client has left. The
  feature, if wanted, is invitations through `playlist-permission/v1`, which is unmeasured and
  a screen of its own.
- **`pl3_version`: nothing to build.** No client sets it.
- **The cover:** `Attributes` gains `picture` (base64, as proto3's JSON mapping renders bytes),
  and a service method runs the three requests in order. Before building it, capture one real
  upload from the web client for the headers and limits, on a playlist made for it. And expect
  the write to need a **re-read**, the way `addTracksToPlaylist` does: the change does not answer
  with the CDN urls of the sizes Spotify generates, and a row holding a stale `ImageSet` is a
  cover that does not change until the next launch.

## Verification

When the cover is built: upload a JPEG as a playlist's cover from the app, see it in the web
player, and see the app's row and page show it without a relaunch.
