# Playlist attributes Spotifly cannot write

Status: **not started** — recorded so the absence is deliberate rather than discovered
Components: `Spotifly/PartnerAPI/PlaylistChanges.swift`, `Spotifly/PartnerAPI/SpclientAPI.swift`,
`Spotifly/Store/Services/PlaylistService.swift`
Recorded: 2026-08-13, splitting the "not built" note out of task 12c in
`single-grant-partner-api.md`

## What is missing, and what is not

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

## Why it is not a defect

There is no screen for any of the three. Nothing in the app offers to change a playlist's cover,
make one collaborative, or touch a version field, so there is no button wired to a call that
silently does nothing. The risk this file exists to prevent is the opposite one: someone reading
`changePlaylistAttributes` and assuming the write path covers the rest of the attributes,
then building a UI on top of it.

## What each would take

**`collaborative` and `pl3_version` are the cheap half.** Both are fields on the same
`ListAttributes` message that `name` and `description` already ride in, so adding them is two
optional properties on `Attributes` plus a service method — no new endpoint, no new shape to
measure. Neither has a screen, so the work is the UI, not the request.

**The cover image is a different job.** It does *not* go in the attributes message: Spotify takes
a playlist image through a separate upload endpoint, and this app has never sent one. That
endpoint's method, path, content type and size limits are all **unmeasured** — nothing here has
been verified against the service, and none of it should be guessed. The way to find out is the
one that settled task 12c: change a playlist's cover in the web client with DevTools open on
Network → Fetch/XHR, and read the request off it. See
[[measure-from-the-web-client-devtools]] — that costs no re-login, where `libspot-probe` revokes
the app's grant every run.

Whoever picks this up should also expect an image write to need a **re-read**, the way
`addTracksToPlaylist` does: the mutation is unlikely to answer with the CDN urls of the sizes
Spotify generated, and a row holding a stale `ImageSet` is a cover that does not change until
the next launch.
