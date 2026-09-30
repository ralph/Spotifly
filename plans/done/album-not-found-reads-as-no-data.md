# An album Spotify cannot find reads as "Spotify returned no data"

Status: **Done** 2026-09-29 (#82). Built, unit-tested, and checked in the running app the same
day with a new debug hook, on `2eb2f4b`, after a loop the first run found was fixed; see
Verification.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`album(id:)`, `artistUnion`,
`PartnerAPIError.notFound`), `Spotifly/PartnerAPI/PathfinderAlbum.swift`,
`Spotifly/PartnerAPI/PathfinderArtist.swift`, `Spotifly/Views/AlbumDetailView.swift`,
`Spotifly/Views/ArtistDetailView.swift`, `Spotifly/Views/Components/InlineLoadError.swift`,
`Spotifly/Views/LoggedInLifecycleModifier.swift` (`SPOTIFLY_DEBUG_OPEN`)
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

### The other kinds

Measured on 2026-09-29 from the web player, with this app's variables:

- **Artists answer the same way.** `queryArtistOverview` and `queryArtistDiscographyAll` for
  `spotify:artist:0000000000000000000000` both answer `{"data":{"artistUnion":{"__typename":
  "NotFound"}}}`. The artist page had the same "Spotify returned no data".
- **An album id that never existed answers like a foreign one**: `NotFound`, the same body. So
  the message cannot promise that the album is only restricted by country.
- **Playlists answered HTTP 500 once.** `fetchPlaylist` for a playlist id that does not exist
  answered HTTP 500 with an empty body. Measured again later the same day, it answers
  `NotFound` like the rest; see `plans/done/playlist-not-found-answers-500.md`.

The web player shows "Album wurde nicht gefunden" and offers a search, not a retry, for the
album. For the artist it shows a generic "something went wrong".

## Solution

- [x] `PathfinderAlbumUnion` and `PathfinderArtistUnion` decode `__typename`.
- [x] `PartnerAPI.album(id:)` and both artist operations throw `PartnerAPIError.notFound(.album)`
      or `.notFound(.artist)` for it, before the empty-payload check further down can.
- [x] The messages: "Spotify can't find this album. It may not be available in your country."
      and "Spotify can't find this artist.", in `de`, `en` and `fr`. The German album one
      begins with the web player's own "Album wurde nicht gefunden". The country is a "may":
      a mistyped id answers the same.
- [x] No retry. `InlineLoadError`'s `retry` is optional, and the album and artist views pass nil
      where `isRetryable(_:)`, beside `isCancellation(_:)`, says asking again cannot help. That covers both of their error branches: the whole page, and the
      track list or discography of an entity already in the store, which is the more likely
      way to meet this. An album from search or a discography can be cached before
      `getAlbum` is ever asked.
- [x] `SPOTIFLY_DEBUG_OPEN=<spotify:album:… or spotify:artist:…>` opens that page in a Debug
      build, since nothing in the app leads to such an id.

### Found in live testing: the page asked again and again

Run in the app on 2026-09-29, the foreign album never showed its message: the page spun, and
the log had `getAlbum` about twenty times a second. A probe logging the view's task and
appearance showed one view instance cycling `task end (error set) → disappear → task start →
appear` every 100 ms. The cause is older than this plan. `AlbumDetailView` put its `.task(id:)`
on a `Group` around the loading, error and content branches, and a `Group` applies its
modifiers to each child. So when the error branch replaced the spinner, the error view's own
task ran `loadAlbum`, which cleared the error, which brought back the spinner and its task.
Any failure of a page's first load looped this way, a network error included. The artist and
playlist pages, Favorites and `LibraryListView` had the same shape, and all five now use a
`ZStack`, a container whose modifiers apply once. With that change the same probe made one
request, ran one task, and showed "Album wurde nicht gefunden…" with no Try again.

## Verification

- [x] Unit tests: the recorded album body throws `notFound` from `album(id:)`, and the recorded
      artist body throws it from both artist operations. Discovery's fixture decodes as `Album`,
      not `NotFound`.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, run bare with the exit
      code checked. 2026-09-29: build succeeded, 380 tests passed, lint exit 0.
- [x] Live, album: run a Debug build with
      `SPOTIFLY_DEBUG_OPEN=spotify:album:2ZWlPOoWh0626oTaHrnl2a` from a DE account. The album
      page says "Album wurde nicht gefunden. Vielleicht ist es in deinem Land nicht verfügbar."
      and has no Try again button. **The first run looped** (see "Found in live testing"
      above). **Passed** on `2eb2f4b`: the message, no Try again, and `getAlbum` once. The
      window's layout squeezed around the message; that is recorded as
      `plans/done/full-page-error-collapses-the-layout.md`.
- [x] Live, artist: `SPOTIFLY_DEBUG_OPEN=spotify:artist:0000000000000000000000`. The artist page
      says "Künstler wurde nicht gefunden." with no Try again. **Passed**, same build, with the
      same layout.
- [x] Live, unchanged: `SPOTIFLY_DEBUG_OPEN=spotify:album:2noRn2Aes5aoNVsU6iWThc` (Discovery, DE)
      opens the album as usual. **Passed**, same build.
- [x] Live, a real failure keeps its retry: Wi-Fi off, open "Anthology 4" from the library.
      The track section says "Es besteht anscheinend keine Verbindung zum Internet." with
      Erneut versuchen; with Wi-Fi back, it loads all 36 tracks. **Passed**, same build. The
      cover went on spinning after that; recorded as
      `plans/done/artwork-stuck-after-network-drop.md`.
