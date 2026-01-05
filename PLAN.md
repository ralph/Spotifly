# Normalized State Management Plan for Spotifly

## Problem Analysis

Your current architecture has several issues causing inconsistency:

1. **Duplicate State**: Same entity (e.g., a track) exists in multiple places with different types (`SearchTrack`, `SavedTrack`, `AlbumTrack`, `PlaylistTrack`)
2. **View-Scoped Data**: Each ViewModel/View fetches and manages its own copy of data
3. **No Central Cache**: When you favorite a track, `FavoritesViewModel` doesn't know, and when you add to a playlist, `PlaylistsViewModel.trackCount` doesn't update
4. **Denormalized Relationships**: Artist names stored as strings instead of references, making updates impossible to propagate

## Proposed Architecture

### 1. Unified Entity Models

Create canonical models that consolidate the various response types:

```swift
// A single Track entity that can be constructed from any API response type
struct Track: Identifiable, Sendable {
    let id: String
    let name: String
    let uri: String
    let durationMs: Int
    let trackNumber: Int?      // Only for album tracks
    let externalUrl: String?

    // Relationships stored as IDs (not nested objects)
    let albumId: String?
    let artistId: String
    let artistName: String     // Denormalized for display (common pattern)
    let albumName: String?     // Denormalized for display
    let imageURL: String?      // Album art (denormalized)
}

struct Album: Identifiable, Sendable {
    let id: String
    let name: String
    let uri: String
    let imageURL: String?
    let releaseDate: String?
    let albumType: String?
    let externalUrl: String?

    let artistId: String
    let artistName: String     // Denormalized
    var trackIds: [String]     // Ordered list of track IDs
    var totalDurationMs: Int?  // Computed when tracks loaded
}

struct Artist: Identifiable, Sendable {
    let id: String
    let name: String
    let uri: String
    let imageURL: String?
    let genres: [String]
    let followers: Int?
}

struct Playlist: Identifiable, Sendable {
    let id: String
    var name: String           // Mutable - can be edited
    var description: String?
    var imageURL: String?
    let uri: String
    var isPublic: Bool
    let ownerId: String
    let ownerName: String

    var trackIds: [String]     // Ordered list of track IDs
    var totalDurationMs: Int?  // Computed when tracks loaded

    var trackCount: Int { trackIds.count }
}
```

### 2. Normalized Store Structure

```swift
@Observable
@MainActor
final class AppStore {
    // === ENTITY TABLES (normalized) ===
    // Dictionary lookups by ID - single source of truth
    private(set) var tracks: [String: Track] = [:]
    private(set) var albums: [String: Album] = [:]
    private(set) var artists: [String: Artist] = [:]
    private(set) var playlists: [String: Playlist] = [:]

    // === USER LIBRARY STATE ===
    // IDs only - actual entities live in tables above
    private(set) var userPlaylistIds: [String] = []      // Ordered
    private(set) var userAlbumIds: [String] = []         // Ordered
    private(set) var userArtistIds: [String] = []        // Ordered
    private(set) var favoriteTrackIds: Set<String> = []  // Unordered set for O(1) lookup
    private(set) var savedTrackIds: [String] = []        // Ordered for display

    // === PAGINATION STATE ===
    // Track what's been loaded and if there's more
    var playlistsPagination = PaginationState()
    var albumsPagination = PaginationState()
    var artistsPagination = PaginationState()
    var favoritesPagination = PaginationState()

    // === LOADING STATE ===
    var loadingStates: [EntityType: Bool] = [:]

    // === COMPUTED PROPERTIES (derived state) ===
    var userPlaylists: [Playlist] {
        userPlaylistIds.compactMap { playlists[$0] }
    }

    var userAlbums: [Album] {
        userAlbumIds.compactMap { albums[$0] }
    }

    var favoriteTracks: [Track] {
        savedTrackIds.compactMap { tracks[$0] }
    }

    func isFavorite(_ trackId: String) -> Bool {
        favoriteTrackIds.contains(trackId)
    }
}

struct PaginationState {
    var isLoaded = false
    var hasMore = true
    var nextOffset: Int? = 0
    var nextCursor: String? = nil
    var total: Int = 0
}

enum EntityType {
    case playlists, albums, artists, tracks, favorites
}
```

### 3. Actions Pattern (Mutations)

All state mutations go through explicit action methods on the store:

```swift
extension AppStore {
    // === ENTITY INSERTION (from API responses) ===

    func upsertTrack(_ track: Track) {
        tracks[track.id] = track
    }

    func upsertTracks(_ newTracks: [Track]) {
        for track in newTracks {
            tracks[track.id] = track
        }
    }

    func upsertPlaylist(_ playlist: Playlist) {
        playlists[playlist.id] = playlist
    }

    // === USER ACTIONS ===

    func addTrackToFavorites(_ trackId: String) {
        favoriteTrackIds.insert(trackId)
        if !savedTrackIds.contains(trackId) {
            savedTrackIds.insert(trackId, at: 0)  // New favorites at top
        }
    }

    func removeTrackFromFavorites(_ trackId: String) {
        favoriteTrackIds.remove(trackId)
        savedTrackIds.removeAll { $0 == trackId }
    }

    func addTrackToPlaylist(_ trackId: String, playlistId: String) {
        playlists[playlistId]?.trackIds.append(trackId)
        // Duration updates automatically via computed property
    }

    func removeTrackFromPlaylist(_ trackId: String, playlistId: String) {
        playlists[playlistId]?.trackIds.removeAll { $0 == trackId }
    }

    func updatePlaylistDetails(id: String, name: String?, description: String?, isPublic: Bool?) {
        if let name = name { playlists[id]?.name = name }
        if let description = description { playlists[id]?.description = description }
        if let isPublic = isPublic { playlists[id]?.isPublic = isPublic }
    }
}
```

### 4. Services Layer (API + Store Integration)

Services handle API calls and update the store on success:

```swift
@MainActor
final class PlaylistService {
    private let store: AppStore
    private let session: SpotifySession

    init(store: AppStore, session: SpotifySession) {
        self.store = store
        self.session = session
    }

    // Load user playlists with caching
    func loadUserPlaylists(forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh
        if store.playlistsPagination.isLoaded && !forceRefresh {
            return
        }

        store.loadingStates[.playlists] = true
        defer { store.loadingStates[.playlists] = false }

        let response = try await SpotifyAPI.fetchUserPlaylists(
            accessToken: session.accessToken,
            limit: 50,
            offset: forceRefresh ? 0 : (store.playlistsPagination.nextOffset ?? 0)
        )

        // Normalize and store
        let normalizedPlaylists = response.playlists.map { Playlist(from: $0) }
        for playlist in normalizedPlaylists {
            store.upsertPlaylist(playlist)
        }

        if forceRefresh {
            store.userPlaylistIds = normalizedPlaylists.map(\.id)
        } else {
            store.userPlaylistIds.append(contentsOf: normalizedPlaylists.map(\.id))
        }

        store.playlistsPagination.isLoaded = true
        store.playlistsPagination.hasMore = response.hasMore
        store.playlistsPagination.nextOffset = response.nextOffset
        store.playlistsPagination.total = response.total
    }

    // Add track to playlist - optimistic update pattern
    func addTrackToPlaylist(trackId: String, playlistId: String) async throws {
        let trackUri = "spotify:track:\(trackId)"

        // Make API call first
        try await SpotifyAPI.addTracksToPlaylist(
            playlistId: playlistId,
            trackUris: [trackUri],
            accessToken: session.accessToken
        )

        // On success, update store (triggers UI update everywhere)
        store.addTrackToPlaylist(trackId, playlistId: playlistId)
    }
}

@MainActor
final class TrackService {
    private let store: AppStore
    private let session: SpotifySession

    func toggleFavorite(trackId: String) async throws {
        let isCurrentlyFavorite = store.isFavorite(trackId)

        if isCurrentlyFavorite {
            try await SpotifyAPI.removeSavedTrack(trackId: trackId, accessToken: session.accessToken)
            store.removeTrackFromFavorites(trackId)
        } else {
            try await SpotifyAPI.saveTrack(trackId: trackId, accessToken: session.accessToken)
            store.addTrackToFavorites(trackId)
        }
    }

    // Check favorite status for tracks, updating store
    func checkFavoriteStatus(trackIds: [String]) async throws {
        let statuses = try await SpotifyAPI.checkSavedTracks(
            trackIds: trackIds,
            accessToken: session.accessToken
        )

        for (trackId, isFavorite) in statuses {
            if isFavorite {
                store.favoriteTrackIds.insert(trackId)
            } else {
                store.favoriteTrackIds.remove(trackId)
            }
        }
    }
}
```

### 5. View Integration

Views read from the store and call services for mutations:

```swift
struct PlaylistsView: View {
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService

    var body: some View {
        List(store.userPlaylists) { playlist in
            PlaylistRow(playlist: playlist)
        }
        .task {
            try? await playlistService.loadUserPlaylists()
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack {
            // Image, name, etc.
            Text(playlist.name)
            Spacer()
            // Track count updates automatically when tracks added/removed
            Text("\(playlist.trackCount) tracks")
        }
    }
}

struct TrackRow: View {
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService

    let track: Track

    var body: some View {
        HStack {
            Text(track.name)
            Spacer()

            // Favorite status from single source of truth
            Button {
                Task { try? await trackService.toggleFavorite(trackId: track.id) }
            } label: {
                Image(systemName: store.isFavorite(track.id) ? "heart.fill" : "heart")
            }
        }
    }
}
```

### 6. App Setup

```swift
@main
struct SpotiflyApp: App {
    @State private var store = AppStore()
    @State private var session = SpotifySession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(session)
                .environment(PlaylistService(store: store, session: session))
                .environment(TrackService(store: store, session: session))
                .environment(AlbumService(store: store, session: session))
                .environment(ArtistService(store: store, session: session))
        }
    }
}
```

## Data Flow Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                         VIEW LAYER                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ PlaylistView│  │ SearchView  │  │ FavoritesView│             │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │ reads          │ reads          │ reads               │
└─────────┼────────────────┼────────────────┼─────────────────────┘
          │                │                │
          ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      APP STORE (@Observable)                     │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Entity Tables (normalized)                              │    │
│  │  tracks: [ID: Track]  albums: [ID: Album]               │    │
│  │  artists: [ID: Artist]  playlists: [ID: Playlist]       │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  User Library State (IDs only)                          │    │
│  │  userPlaylistIds: [ID]  favoriteTrackIds: Set<ID>       │    │
│  └─────────────────────────────────────────────────────────┘    │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               │ mutates
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      SERVICES LAYER                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │PlaylistSvc  │  │ TrackSvc    │  │ AlbumSvc    │              │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                      │
└─────────┼────────────────┼────────────────┼─────────────────────┘
          │                │                │
          │ API calls      │ API calls      │ API calls
          ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      SPOTIFY API                                 │
│                    (SpotifyAPI.swift)                            │
└─────────────────────────────────────────────────────────────────┘
```

## Key Benefits

1. **Consistency**: When you favorite a track, `favoriteTrackIds` updates once, and ALL views reading it update automatically
2. **Efficiency**: Tracks/albums/artists cached by ID - no duplicate fetches
3. **Simplicity**: Views just read computed properties, services handle complexity
4. **Testability**: Services can be mocked, store state is predictable

## Migration Strategy

### Phase 1: Core Infrastructure
1. Create unified entity models (`Track`, `Album`, `Artist`, `Playlist`)
2. Create `AppStore` with entity tables
3. Add conversion initializers (e.g., `Track(from: SearchTrack)`)

### Phase 2: Services
1. Create service classes (`PlaylistService`, `TrackService`, etc.)
2. Services use existing `SpotifyAPI` methods
3. Services normalize responses and update store

### Phase 3: View Migration
1. Update views one-by-one to use store + services
2. Keep existing ViewModels working during migration
3. Remove old ViewModels as views migrate

### Phase 4: Cleanup
1. Remove redundant API response types (keep for API parsing, but normalize immediately)
2. Remove old ViewModels
3. Add optimistic updates where appropriate

## Questions for You

1. **Optimistic vs Pessimistic Updates**: Should we update UI immediately before API success (optimistic, faster UX) or wait for confirmation (pessimistic, safer)? I'd recommend optimistic for favorites/queue, pessimistic for playlist edits.

2. **Cache Invalidation**: How aggressive should we be about re-fetching? Options:
   - Time-based (re-fetch if data is > X minutes old)
   - Pull-to-refresh only
   - Background refresh on app foreground

3. **Offline Considerations**: Should we persist the store to disk for offline viewing?

4. **PlaybackViewModel**: This is currently a singleton. Should it stay separate or integrate into AppStore?
