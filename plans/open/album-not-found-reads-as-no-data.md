# An album Spotify cannot find reads as "Spotify returned no data"

Status: **Open.** Recorded, not planned. Not urgent: no path in the app is known to reach it.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`album(id:)`),
`Spotifly/PartnerAPI/PathfinderEntities.swift` (`PathfinderAlbumUnion.entities()`),
`Spotifly/Store/Services/AlbumService.swift` (`loadAlbum`),
`Spotifly/Views/AlbumDetailView.swift`
Found: 2026-09-29, while verifying the hash refresh in #77.

## Summary

For an album that does not exist in the account's market, `getAlbum` answers HTTP 200 with
`albumUnion` of type `NotFound`. The app treats that as an empty response and shows "Spotify
returned no data" with a Try again button that can never succeed. It should say the album is
not available.

## Problem

### What Spotify sends

Discovery's US id, `spotify:album:2ZWlPOoWh0626oTaHrnl2a`, asked for from a DE account. This is
the current `getAlbum` hash; the previous one answered the same `NotFound`, without `meV2`:

```json
{"data":{"albumUnion":{"__typename":"NotFound"},"meV2":{"ianaTimezoneId":"Europe/Berlin"}}}
```

### What the app does with it

- `PartnerAPI.album(id:)` only checks that `albumUnion` is there, and it is.
- `PathfinderAlbumUnion.entities()` finds no `uri`, so no id, and returns nil.
- `AlbumService.loadAlbum` turns that into `PartnerAPIError.emptyPayload`.
- `AlbumDetailView` shows its `localizedDescription`, "Spotify returned no data", in
  `InlineLoadError`, with a Try again button.

### How the app could get such an id

None is known. Measured on 2026-09-29:

- Every album the app gets from pathfinder is resolved for the account's market: search, home,
  the library, an artist's discography, a track's album. All 46 saved albums answered `Album`.
- An unplayable track's album is not `NotFound`. The albums of all 221 country-restricted
  Liked Songs tracks, three albums, answered `Album`, with tracks that cannot play.
- The app opens no album links. Only `open.spotify.com/track/…` links are parsed, and
  `handlesExternalEvents` only brings the window forward.

Not checked: a Connect context from another device naming an album, which is unlikely on the
same account; and a track from another market, which spclient returns as asked for and whose
album could be foreign, if the app can be given such a track at all.

## Solution

Not planned yet. The likely fix: `album(id:)` recognises `__typename == "NotFound"` and throws
a dedicated error that reads "This album isn't available in your country" and offers no retry.
Whether `artistUnion` and `playlistV2` answer the same way for their kinds is not checked.

## Verification

Not defined yet. The recorded body above is enough for a unit test of the decoding and the
error. A live check needs a way to open an album by id.
