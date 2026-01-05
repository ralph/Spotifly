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
