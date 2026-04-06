# Spotifly

Spotify client for macOS (and maybe later iPad and iOS).

## Tech Stack

- **Language**: Swift 6.2 with strict concurrency enabled
- **Target Platforms**: Latest Apple OSes only (macOS, iOS, iPadOS)
- **UI Framework**: SwiftUI

## Development Guidelines

- Use Swift 6.2 strict concurrency features (`Sendable`, `@MainActor`, async/await)
- No backwards compatibility needed - target only the latest OS versions
- Format all Swift code with: `swiftformat --swiftversion 6.2 .`

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
- Favorite tracking: `favoriteTrackIds` set for O(1) lookup
- Injected via `@Environment(AppStore.self)`

**Entities** (`Store/Entities.swift`)
- Unified data models: `Track`, `Album`, `Artist`, `Playlist`, `Device`
- Decoupled from API response types (conversions in `EntityConversions.swift`)

**Services** (`Store/Services/`)
- Handle API calls and update AppStore on success
- Each service takes `AppStore` in its initializer
- Injected via `@Environment(XxxService.self)`
- Available services: `TrackService`, `AlbumService`, `ArtistService`, `PlaylistService`, `DeviceService`, `QueueService`, `RecentlyPlayedService`, `SearchService`

### Usage Pattern

```swift
struct MyView: View {
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService

    // Read from store
    private var tracks: [Track] {
        store.albums[albumId]?.trackIds.compactMap { store.tracks[$0] } ?? []
    }

    // Mutate via service
    func loadTracks() async {
        _ = try? await albumService.getAlbumTracks(albumId: id, accessToken: token)
        // Tracks are now in store.tracks, view updates automatically
    }
}
```

### Key Principles

1. **Always use services for API calls** - ensures entities are stored in AppStore
2. **Read from store, write via services** - single source of truth
3. **Favorites require tracks in store** - `store.isFavorite(trackId)` only works if track was loaded via a service
4. **Favorites loaded on startup** - `LoggedInView` loads favorites so heart indicators work everywhere

### Network Request Deduplication

Views using `.task` to load data need protection against duplicate requests. The approach depends on whether the view's layout can change:

- **Stable views** (no layout changes): Simple `guard !store.xxxPagination.isLoading` in the service is sufficient
- **Layout-switching views** (Albums/Artists/Playlists trigger 2→3 column switch): The service must store the `Task` reference and be persisted via `@State` in a parent view, because view recreation can re-trigger `.task` before `isLoading` is set

The stored task pattern in `AlbumService`/`ArtistService`/`PlaylistService`:
```swift
if let existingTask = userAlbumsTask {
    _ = try? await existingTask.value  // Await existing, don't start new
    return
}
```

These services are stored as `@State` in `LoggedInView` so the task reference survives view recreation. If adding a new section that changes the column layout, use this pattern.

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
