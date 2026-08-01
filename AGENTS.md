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

All Spotify API network requests must include debug logging. Add a log statement after constructing the URL string, wrapped in `#if DEBUG`:

```swift
let urlString = "\(baseURL)/endpoint"
#if DEBUG
    apiLogger.debug("[METHOD] \(urlString)")
#endif
```

- Use the appropriate HTTP method: `[GET]`, `[POST]`, `[PUT]`, `[DELETE]`
- The `apiLogger` is defined at the top of `SpotifyAPI.swift`
- Logs are only compiled in debug builds (zero overhead in release)

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
