# Playlist attributes Spotifly cannot write

Status: **Done** 2026-10-02 for the cover: a playlist's owner can set it from an image file and
remove it, and the app shows it without a relaunch. Seen in the running app and the web player;
see Verification. `collaborative` and `pl3_version` are left: the current client sets neither as an
attribute (see Solution).
Components: `Spotifly/PartnerAPI/PlaylistChanges.swift`, `Spotifly/PartnerAPI/SpclientAPI.swift`,
`Spotifly/Store/Services/PlaylistService.swift`, `Spotifly/Store/Services/PlaylistCoverImage.swift`,
`Spotifly/Views/LoggedInToolbars.swift`, `Spotifly/Views/PlaylistDetailView.swift`
Found: 2026-08-13, splitting the "not built" note out of task 12c in
`plans/done/single-grant-partner-api.md`

## Summary

Spotifly wrote a playlist's name and description. It could not set the cover image, whether the
playlist is collaborative, or `pl3_version`. Reading was complete: cover art showed everywhere it
should.

## Problem

### What was missing, and what was not

**Reading was complete. This was only about writing.** Cover art displays everywhere it should:
`PathfinderPlaylist.images` decodes it, `Playlist.images` holds it as an `ImageSet`, and the
views render it.

What Spotifly couldn't do was *set* three things on a playlist:

| Attribute | State |
| --- | --- |
| `name` | written: `PlaylistOp.attributes(name:description:)` |
| `description` | written: same call |
| cover image | written since 2026-10-02: `SpclientAPI.changePlaylistCover`, `removePlaylistCover` |
| `collaborative` | not written, and not an attribute in the current client |
| `pl3_version` | not written; no client sets it |

`PlaylistOp.Attributes` models only what the app sets: name, description, and now `picture`.
`ListAttributesPartialState`'s partial semantics stay honest that way: a nil field is left out
and the existing value stands. A field taken away is named in `noValue`.

### Why it was not a defect

No screen offered any of the three, so no button was wired to a call that did nothing. This file
existed so no one would read `changePlaylistAttributes` as covering the rest of the attributes and
build a UI on it.

## Solution

### What the web client does

Read from its bundle on 2026-09-29, then captured from the web player on 2026-10-02 on a playlist
made for it ("Meine Playlist Nr. 41"), with a `fetch` wrapper in the page:

- **Choosing the image** uploads it at once, before Save: `POST
  https://image-upload.spotify.com/v4/playlist`.
  - Body: the file as picked, unchanged (a 24 KB JPEG); `Content-Type: image/jpeg`.
  - Headers: the bearer and the client token.
  - Answer: `{"uploadToken": …}`, 111 characters.
  - The picker takes `.jpg`, `.jpeg` and `.png`.
- **Save**:
  - `POST playlist/v2/playlist/{id}/register-image` with `{"uploadToken": …}`, which answers
    `{"picture": …}`, 28 characters of base64;
  - then that `picture` in an `UPDATE_LIST_ATTRIBUTES` change to `playlist/v2/playlist/{id}/changes`,
    the request a rename sends.
- **"Foto entfernen"** sends one change: `{"values":{},"noValue":["LIST_PICTURE"]}`.
- **`collaborative`** is never set; collaboration is invitations through `playlist-permission/v1`.
  **`pl3_version`** isn't set either.

### What is built

- **Requests:** `PlaylistOp.picture(_:)` and `.removePicture`. `SpclientAPI.changePlaylistCover`
  runs the three requests in order, the upload through the same signed `send` as the writes;
  `removePlaylistCover` sends the removal.
- **The image:** `PlaylistCoverImage.jpeg(from:)` takes any image ImageIO reads, turned as its
  orientation says. It sends the centre square at most 640 pixels a side, as a JPEG. The web
  player sends the file as picked. Cropping here makes the cover the one the user sees, and
  scaling keeps a photo's megabytes off a request whose limit isn't measured.
- **The store:** `PlaylistService.changePlaylistCover` and `removePlaylistCover` read the playlist
  again afterwards. The change answers nothing about the sizes Spotify makes, and the re-read
  brings the new cover url at once (2026-10-02).
- **The screen:** for the playlist's owner, a cover menu in the toolbar:
  - "Choose Image…" opens a file picker (`.fileImporter`, the sandbox's user-selected read
    grant);
  - "Remove Image" takes the cover away.

  Errors show where the playlist page shows the others.

### Left

- **`collaborative`: not as an attribute.** The current client doesn't set the flag; the feature
  would be invitations through `playlist-permission/v1`, unmeasured and a screen of its own.
- **`pl3_version`: nothing to build.**
- **The upload's size limit** isn't measured. The app sends at most a 640-pixel JPEG.

## Verification

- **Unit tests:**
  - the cover and removal bodies match the web player's;
  - the three requests go in order, to their hosts and paths, with the image and its content
    type;
  - an upload that fails registers nothing, and a file that isn't an image sends nothing;
  - a wide and a tall image become their centre square at 640 pixels, and a small one is cut,
    not scaled up.
- **Live, 2026-10-02**, Debug build, the test playlist "Meine Playlist Nr. 41":
  - **Choosing an image:** "Bild auswählen …" in the toolbar's cover menu opened the picker.
    A 1600 × 900 PNG went up as its centre square (upload 2 s, then register, change and
    re-read), and the header and the library row showed it at once. So did the web player.
  - **Removing it:** "Bild entfernen" sent the removal, and the header and row went back to the
    placeholder.
  - Before that, a throwaway launch hook ran the service on the same image, with the same
    result in the app and the web player.
