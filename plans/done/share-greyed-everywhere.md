# Share is greyed for every playlist, album, artist and track

Status: **Done** 2026-10-02. Every entity's link comes from its uri. Seen in the running app for a
playlist, an album, an artist and a track, and each link opened its page in the web player; see
Verification.
Components: `Spotifly/Store/Entities.swift` (`externalUrl`),
`Spotifly/PartnerAPI/PathfinderSearch.swift` (`SpotifyURI.webURL`),
`Spotifly/PartnerAPI/PathfinderEntities.swift`, `Spotifly/PartnerAPI/SpclientEntities.swift`
Found: 2026-10-02, reported by the user: sharing a playlist seemed broken

## Summary

Share copies an entity's open.spotify.com link: the toolbar's for a playlist, an album and an
artist, and a track's context menu. Every entity's link was nil, so Share was greyed everywhere.

## Problem

- **Where the link came from:** the Web API answered every entity with
  `external_urls.spotify`, which the entities kept as `externalUrl`. Pathfinder and spclient
  answer no such field. Since the move to them (`plans/done/single-grant-partner-api.md`), every
  place that builds an entity wrote `externalUrl: nil`: 13 in `PathfinderEntities.swift`, one in
  `SpclientEntities.swift`, and one in `PlaylistService.createPlaylist`.
- **What it greyed:**
  - `ShareToolbarButton` is disabled for a nil link: the playlist, album and artist toolbars.
  - `TrackContextMenu`'s Share is disabled for a nil link.
- **Not affected:** the profile's link, which `UserProfile(pathfinder:)` already builds from the
  username.

## Solution

The link is the uri's, so it's derived rather than stored. `SpotifyURI.webURL` maps
`spotify:<kind>:<id>` to `https://open.spotify.com/<kind>/<id>` for the kinds that have a page
there (track, album, artist, playlist, show, episode, user). A folder, a local file or a station
gets none.

`Track`, `Album`, `Artist` and `Playlist` answer `externalUrl` from their uri. The stored field and
the `externalUrl: nil` at every construction site are gone, so a new entity can't be built
without one again.

## Verification

- **Unit tests:** the link for each kind; none for what has no page; each entity Share is
  offered for has its link.
- **Live, 2026-10-02**, Debug build:
  - Share in the toolbar copied:
    - for the test playlist, `https://open.spotify.com/playlist/3z9hP42BTLFUL6dxNMHyHe`;
    - for "Never/Know", `…/album/4ifWQZN7li3ij532LR1l0q`;
    - for Rodríguez, `…/artist/5PrHzxc3kFm4hIrGNmelpX`.
  - A track's context menu offered Share, and it copied `…/track/65fakZn6WNFDM29vjYrzK0`.
  - Each link opened its page in the web player ("Never Know", "Never/Know", "Rodríguez").
  - Before the fix, Share was greyed in the playlist's toolbar.
