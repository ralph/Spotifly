# Spotifly

Spotify client for macOS (and maybe later iPad and iOS).

## Tech Stack

- **Language**: Swift 6.3 with strict concurrency enabled
- **Target Platforms**: Latest Apple OSes only (macOS, iOS, iPadOS)
- **UI Framework**: SwiftUI

## Development Guidelines

- Use Swift 6.3 strict concurrency features (`Sendable`, `@MainActor`, async/await)
- No backwards compatibility needed - target only the latest OS versions
- Format all Swift code with: `swiftformat --swiftversion 6.3 .`

Also read `AGENTS-twostraws.md` for general development guidelines and best practices inspired by Paul Hudson's "Two Straws" approach.

## Network Request Logging

All Spotify API network requests must include debug logging. Add a log statement after constructing the URL string:

```swift
let urlString = "\(baseURL)/endpoint"
debugLog("SpotifyAPI", "[GET] \(urlString)")
```

- Use the appropriate HTTP method: `[GET]`, `[POST]`, `[PUT]`, `[DELETE]`
- The first argument names the module making the request — `"SpotifyAPI"`, `"KeymasterAuth"`, and so on
- `debugLog` lives in `DebugLog.swift` and compiles to an empty inlinable function outside DEBUG builds, so it needs no `#if DEBUG` around it

## Track identity is the market id

**A track can have two ids.** When a recording is not playable in the account's market,
Spotify substitutes one that is — a different `id` and `uri` for what a listener would call
the same song. The Web API names both, returning the substitute as `id` and the id you asked
for under `linked_from`. Which one you get depends on the endpoint and on `market`.

**The rule: the app keys everything on the id the API returned, and never rewrites it.**
Store keys, favorites, queue position, playback, writes — all the market id. Nothing in the
app reconstructs an original, and no code should start.

The reason is that reconstruction is no longer possible. Search now runs on pathfinder, which
returns the market recording and carries **no `linked_from`** — there is nothing to trade the
substitute back for, and the substitute looks canonical from every angle. spclient is
id-faithful: it returns whatever id you ask for, so it hydrates entities without ever
introducing a second identity. Measured against a known pair on 2026-08-13 (Xavier Rudd, "The
Letter": original `459GknUJgpky3io0y482bi`, DE substitute `7FcObTmCbQYyC8qzlTL2SE`); the
detail is in `plans/single-grant-partner-api.md`.

So the choice is only *which* id every path agrees on, and the market id is the one every
path can produce. Send `market=from_token` everywhere it is supported and let the answer
stand: that is what makes a searched track and a saved track the same track.

**This reverses the earlier rule**, which normalised back to the original through a
`RelinkableTrackCodable` protocol — the reasoning is in
`plans/relinked-track-now-playing-identity.md` and `plans/web-api-track-relinking-identity.md`,
both now historical. That rule existed because Spotify's
[relinking docs](https://developer.spotify.com/documentation/web-api/concepts/track-relinking)
require the original id for Web API writes. It stopped being available once search moved to
pathfinder, and the mismatch it caused was live: a relinked track favorited from search saved
one id while the library row held the other, so the heart did not light and removal missed.

What the old rule was *right* about, and what still holds: **one identity per track, or the
store corrupts.** Two ids for one song means the queue points at a key `store.tracks` misses,
the track re-fetches forever behind a placeholder, and the recovery loader writes a second
entity. Consistency is the requirement; which id carries it is not.

**Writes are the open edge.** Spotify's docs say a substitute id "will likely return an error
or other unexpected result" for saves and removals, and `saveTrack`, `removeSavedTrack`,
`checkSavedTracks` and playlist removal still go to `api.spotify.com` until Phase 4. That
warning is written for third-party Web API clients; Spotify's own client only ever holds
market ids, since pathfinder gives it nothing else, and it saves from search perfectly well —
so the native collection path these writes are moving to must accept them. Until that move
lands, treat Web API write behaviour with a substitute id as measured-not-assumed.

**There is more than one track-shaped response type**, which is the part that bites.
`TrackCodable` serves most endpoints, but `/albums/{id}/tracks` decodes through
`AlbumTracksCodable.AlbumTrackItemCodable`, with its own fields and its own `toAPITrack()`.
Under the old rule a type that forgot to conform silently dropped the recovery field; under
this one the failure mode is the reverse — a hand-written conversion that reintroduces an
original id from somewhere. Either way the request looks correct and the store is wrong.

**When adding or changing a track-returning request:**

- send `market=from_token` where the endpoint supports it, so the id matches what pathfinder
  and playback use;
- do not project or read `linked_from`; if a response carries one, ignore it;
- build entities through `toAPITrack()` rather than field by field. A hand-written conversion
  is how `/search` once came to disagree with everything around it while looking reasonable;
- where a codable is consumed directly, as the playback bootstrap does, read `id` and `uri`.

## State Management Architecture

The app uses a normalized state store pattern (similar to Pinia/Redux) for data management.

### Core Components

**AppStore** (`Store/AppStore.swift`)
- Single source of truth for all entity data
- Normalized entity tables: `tracks`, `albums`, `artists`, `playlists`, `devices`
- ID arrays for ordered collections: `savedTrackIds`, `userPlaylistIds`, `userAlbumIds`, `userArtistIds`
- Injected via `@Environment(AppStore.self)`

**Entities** (`Store/Entities.swift`)
- Unified data models: `Track`, `Album`, `Artist`, `Playlist`, `Device`
- Decoupled from API response types (conversions in `EntityConversions.swift`)

**Services** (`Store/Services/`)
- Handle API calls and update AppStore on success
- Each service takes `AppStore` in its initializer
- Injected via `@Environment(XxxService.self)`
- Available services: `TrackService`, `AlbumService`, `ArtistService`, `PlaylistService`, `DeviceService`, `QueueService`, `RecentlyPlayedService`, `SearchService`

### Network Request Deduplication

Every fetch goes through `InFlightRequests` (`Store/Services/InFlightRequests.swift`), a
keyed single-flight registry. A second caller for the same key awaits the run the first
one started, and the run is an *unstructured* Task, so it is not cancelled when its
caller is — SwiftUI cancels a view's `.task` on teardown, and the detail views are torn
down routinely (selection changes, section switches, the 2→3 column flip). The result
lands in `AppStore` either way, and whatever view replaces the cancelled one reads it
from there.

```swift
try await albumRequests.run(albumId) {
    try await self.loadAlbum(albumId: albumId, accessToken: self.tokenProvider())
}
```

Requests that carry **many IDs at once** use `BatchInFlightRequests`
(`Store/Services/BatchInFlightRequests.swift`) instead, because one key to one run does
not fit them: `/v1/tracks` and `/me/tracks/contains` cover a whole batch, and the next
caller arrives with an overlapping but different set. It joins the runs already carrying
some of its IDs and starts one run for the remainder, which it hands to the operation:

```swift
try await metadataLoads.run(missingTrackIds) { uncoveredTrackIds in
    // fetch only the IDs no current run covers
}
```

Same guarantees as the keyed registry — unstructured runs, cache check before the token,
entries dropped on failure so the next caller retries. `TrackService` owns both batch
registries; route new track metadata through `ensureTracksLoaded(trackIds:)` rather than
adding a second fetch path.

Rules when adding a loading path:

- **A key means one postcondition.** `album:<id>` always means "metadata *and* tracks are
  in the store". Two operations that fetch different amounts may not share a key.
- **Check the cache before the token.** Services hold a `tokenProvider` and take the
  token inside the run, after the early returns, so a cache hit costs nothing.
- **A superseded run must not write.** `cancel(_:)` only asks; call
  `try Task.checkCancellation()` after the network call, before touching the store.
- **Cache what was fetched, not what is non-empty.** `detailsLoaded` / `tracksLoaded` are
  set by the load, so a genuinely empty album is not re-fetched forever.
- **Views read the store**, never a `@State` copy of an entity.

The services are stored as `@State` in `LoggedInView` so their registries survive view
recreation. `plans/section-request-pattern.md` has the full reasoning.

## Debug Logging

### Spirc/Connect Trace Logging

To see raw Spirc state transitions during development, set the `RUST_LOG` environment variable:

```bash
RUST_LOG=librespot_connect::spirc=trace ./path/to/Spotifly.app/Contents/MacOS/Spotifly
```

Or in Xcode scheme (Edit Scheme → Run → Arguments → Environment Variables):
- Name: `RUST_LOG`
- Value: `librespot_connect::spirc=trace`

This shows Mercury frames, Connect state changes, and device updates.

## Changelog & Releases

### Changelog Management

- Keep `CHANGELOG.md` in this repo up to date with all changes (detailed, technical notes welcome)
- Use [Keep a Changelog](https://keepachangelog.com/) format with sections: Added, Changed, Fixed, Removed
- Add entries under `## [Unreleased]` as you work

### Release Process

When ready to release, run: `/release [version]` (e.g., `/release 1.1.5`)

This will:
1. Move `[Unreleased]` entries to a new version section with today's date
2. Bump `MARKETING_VERSION` in the Xcode project
3. Update `../homebrew-spotifly/CHANGELOG.md` with user-facing summary (temporary)
4. Commit both repos

After `/release`, you must:
1. Push both repos
2. Create a GitHub Release in this repo with the built .zip artifact
3. Update the Homebrew formula in homebrew-spotifly (URL + SHA256)

### About homebrew-spotifly

The `../homebrew-spotifly` repo is temporary scaffolding for the Homebrew tap. Once the app is accepted into official Homebrew, it will be deleted. Until then:
- Releases are published to **this repo** (ralph/spotifly)
- The homebrew-spotifly repo only contains the tap formula and a user-facing changelog
- Both changelogs are updated during `/release`
