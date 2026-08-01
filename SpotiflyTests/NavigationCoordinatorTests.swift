//
//  NavigationCoordinatorTests.swift
//  SpotiflyTests
//

@testable import Spotifly
import Testing

@MainActor
struct NavigationCoordinatorTests {
    @Test func `every user initiated change is reachable by back`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        var visited = [coordinator.current]

        coordinator.selectNavigationItem(.favorites)
        visited.append(coordinator.current)
        coordinator.selectNavigationItem(.albums)
        visited.append(coordinator.current)
        coordinator.selectAlbum("album-a")
        visited.append(coordinator.current)
        coordinator.push(.artist(id: "artist-a"))
        visited.append(coordinator.current)
        coordinator.selectNavigationItem(.artists)
        visited.append(coordinator.current)
        coordinator.selectArtist("artist-b")
        visited.append(coordinator.current)
        coordinator.push(.album(id: "album-b"))
        visited.append(coordinator.current)
        coordinator.selectNavigationItem(.playlists)
        visited.append(coordinator.current)
        coordinator.selectPlaylist("playlist-a")
        visited.append(coordinator.current)
        coordinator.selectNavigationItem(.queue)
        visited.append(coordinator.current)
        coordinator.selectNavigationItem(nil)
        visited.append(coordinator.current)
        coordinator.selectNavigationItem(.startpage)
        visited.append(coordinator.current)

        for expected in visited.dropLast().reversed() {
            coordinator.navigateBackward()
            #expect(coordinator.current == expected)
        }

        #expect(!coordinator.canNavigateBackward)
        #expect(coordinator.current == .startpage)
    }

    @Test func `forward is cleared by new navigation after going back`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectNavigationItem(.artists)
        coordinator.navigateBackward()

        #expect(coordinator.canNavigateForward)

        coordinator.selectNavigationItem(.favorites)

        #expect(!coordinator.canNavigateForward)
        #expect(coordinator.current.section == .favorites)
    }

    @Test func `back and forward restore the identical route including drill down`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectAlbum("album-a")
        coordinator.push(.artist(id: "artist-a"))
        let expected = coordinator.current

        coordinator.selectNavigationItem(.favorites)
        coordinator.navigateBackward()
        #expect(coordinator.current == expected)

        coordinator.navigateForward()
        #expect(coordinator.current.section == .favorites)
        coordinator.navigateBackward()
        #expect(coordinator.current == expected)
    }

    @Test func `automatic first library selection is not recorded`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectAlbum("album-a", recordsHistory: false)

        #expect(coordinator.current.selection == .album(id: "album-a"))
        #expect(coordinator.back == [.startpage])

        coordinator.navigateBackward()
        #expect(coordinator.current == .startpage)
        #expect(!coordinator.canNavigateBackward)
    }

    @Test func `automatic replacement cannot leave a no-op history step`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectAlbum("album-a")
        coordinator.selectAlbum("album-b")

        coordinator.selectAlbum("album-a", recordsHistory: false)

        #expect(coordinator.back.last != coordinator.current)
        coordinator.navigateBackward()
        #expect(coordinator.current.selection == nil)
    }

    @Test func `drill down through stack path records history`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        let albumsRoute = coordinator.current

        coordinator.setNavigationPath([.artist(id: "artist-a")])

        #expect(coordinator.navigationPath == [.artist(id: "artist-a")])
        coordinator.navigateBackward()
        #expect(coordinator.current == albumsRoute)
    }

    @Test func `native stack pop moves backward instead of recording a new route`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        let root = coordinator.current
        coordinator.push(.album(id: "album-a"))
        let firstPush = coordinator.current
        coordinator.push(.artist(id: "artist-a"))

        coordinator.setNavigationPath(firstPush.path)

        #expect(coordinator.current == firstPush)
        #expect(coordinator.forward.last?.path == [.album(id: "album-a"), .artist(id: "artist-a")])

        coordinator.navigateBackward()
        #expect(coordinator.current == root)
    }

    /// A whole path can be assigned in one step — that is what the binding is for, and what
    /// a deep link would do — so the levels it skips were never locations. Popping out of
    /// one must still move backward rather than recording the deeper view.
    @Test func `a pop to an unrecorded level still moves backward`() {
        let coordinator = NavigationCoordinator(store: AppStore())

        coordinator.selectNavigationItem(.albums)
        coordinator.setNavigationPath([.artist(id: "artist-1"), .album(id: "album-1")])
        coordinator.setNavigationPath([.artist(id: "artist-1")])

        #expect(coordinator.navigationPath == [.artist(id: "artist-1")])

        coordinator.navigateBackward()

        #expect(coordinator.navigationPath.isEmpty)

        coordinator.navigateForward()

        #expect(coordinator.navigationPath == [.artist(id: "artist-1")])
    }

    /// An automatic selection while a drill-down is showing leaves a pending restore
    /// target holding that full path. Popping out of it consumes the write that target was
    /// waiting for, so pushing back must not be mistaken for the restore callback.
    @Test func `a push after popping past a pending restore target is not swallowed`() {
        let coordinator = NavigationCoordinator(store: AppStore())

        coordinator.selectNavigationItem(.albums)
        coordinator.setNavigationPath([.artist(id: "artist-1"), .album(id: "album-1")])
        coordinator.selectAlbum("album-1", recordsHistory: false)
        coordinator.setNavigationPath([.artist(id: "artist-1")])

        coordinator.setNavigationPath([.artist(id: "artist-1"), .album(id: "album-1")])

        #expect(coordinator.navigationPath == [.artist(id: "artist-1"), .album(id: "album-1")])
    }

    /// A pop can skip several levels at once. The levels it skipped were passed through on
    /// the way deeper, so they belong ahead of the user now, not behind.
    @Test func `a pop skipping levels does not leave them behind the user`() {
        let coordinator = NavigationCoordinator(store: AppStore())

        coordinator.selectNavigationItem(.albums)
        coordinator.setNavigationPath([.artist(id: "artist-1"), .album(id: "album-1")])
        coordinator.push(.playlist(id: "playlist-1"))
        coordinator.setNavigationPath([.artist(id: "artist-1")])

        #expect(coordinator.navigationPath == [.artist(id: "artist-1")])

        coordinator.navigateBackward()

        #expect(coordinator.navigationPath.isEmpty)

        coordinator.navigateForward()

        #expect(coordinator.navigationPath == [.artist(id: "artist-1")])

        coordinator.navigateForward()

        #expect(coordinator.navigationPath == [.artist(id: "artist-1"), .album(id: "album-1")])
    }

    @Test func `section reentry restores remembered selection without an extra step`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectAlbum("album-a")
        coordinator.selectNavigationItem(.artists)
        let artistsRoute = coordinator.current

        coordinator.selectNavigationItem(.albums)

        #expect(coordinator.current.selection == .album(id: "album-a"))
        coordinator.navigateBackward()
        #expect(coordinator.current == artistsRoute)
    }

    @Test func `history titles name section selection and drill down targets`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        store.upsertAlbum(album(id: "album-a", name: "Named Album"))
        store.upsertArtist(Artist(
            id: "artist-a",
            name: "Named Artist",
            uri: "spotify:artist:artist-a",
            images: .empty,
            genres: [],
            externalUrl: nil,
        ))

        coordinator.selectNavigationItem(.albums)
        #expect(coordinator.backNavigationTitle == NavigationItem.startpage.title)

        coordinator.selectAlbum("album-a")
        coordinator.navigateBackward()
        #expect(coordinator.forwardNavigationTitle == "Named Album")
        coordinator.navigateForward()

        coordinator.push(.artist(id: "artist-a"))
        coordinator.selectNavigationItem(.favorites)
        #expect(coordinator.backNavigationTitle == "Named Artist")
    }

    @Test func `favorites selection clears drill down state and still records section history`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectAlbum("album-a")
        coordinator.push(.artist(id: "missing-artist"))

        coordinator.selectNavigationItem(.favorites)

        #expect(coordinator.navigationPath.isEmpty)
        #expect(coordinator.viewingAlbumId == nil)
        #expect(coordinator.backNavigationTitle == NavigationItem.albums.title)
        #expect(coordinator.canRefreshCurrentSection)
    }

    @Test func `history cap drops oldest entries and back still works`() {
        let coordinator = NavigationCoordinator(store: AppStore())

        for index in 0 ..< (NavigationCoordinator.historyLimit + 5) {
            coordinator.selectNavigationItem(index.isMultiple(of: 2) ? .albums : .artists)
        }

        #expect(coordinator.back.count == NavigationCoordinator.historyLimit)

        for _ in 0 ..< NavigationCoordinator.historyLimit {
            #expect(coordinator.canNavigateBackward)
            coordinator.navigateBackward()
        }
        #expect(!coordinator.canNavigateBackward)
    }

    @Test func `restoring history does not record another history entry`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectNavigationItem(.favorites)

        coordinator.navigateBackward()

        #expect(coordinator.current.section == .albums)
        #expect(coordinator.back == [.startpage])
        #expect(coordinator.forward.count == 1)

        coordinator.navigateForward()
        #expect(coordinator.current.section == .favorites)
        #expect(coordinator.back.count == 2)
        #expect(coordinator.forward.isEmpty)
    }

    @Test func `clearing sidebar selection records the empty location`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)

        coordinator.selectNavigationItem(nil)

        #expect(coordinator.current.section == nil)
        #expect(coordinator.current.selection == nil)
        #expect(coordinator.current.path.isEmpty)
        coordinator.navigateBackward()
        #expect(coordinator.current.section == .albums)
    }

    @Test func `revisiting a route retains both nonadjacent entries`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.selectNavigationItem(.albums)
        coordinator.selectNavigationItem(.startpage)

        coordinator.navigateBackward()
        #expect(coordinator.current.section == .albums)
        coordinator.navigateBackward()
        #expect(coordinator.current == .startpage)
    }

    @Test func `invalidation removes a deleted playlist from both history directions`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        let playlist = playlist(id: "playlist-a")
        store.upsertPlaylist(playlist)
        store.addPlaylistToUserLibraryById(playlist.id)

        coordinator.navigateToPlaylistSection(playlistId: playlist.id)
        coordinator.selectNavigationItem(.albums)
        coordinator.navigateToPlaylistSection(playlistId: playlist.id)
        coordinator.navigateBackward()

        store.removePlaylistFromUserLibrary(playlist.id)
        coordinator.invalidateUnviewableRoutes()

        #expect(coordinator.current.section == .albums)
        #expect(!coordinator.back.contains { $0.selection == .playlist(id: playlist.id) })
        #expect(!coordinator.forward.contains { $0.selection == .playlist(id: playlist.id) })

        coordinator.selectNavigationItem(.playlists)
        #expect(coordinator.current.selection == nil)
    }

    @Test func `invalidation removes an evicted search from the whole history`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        store.setSearchResults(emptySearchResults, for: "old")
        coordinator.navigateToSearchResults(query: "old")
        coordinator.selectNavigationItem(.albums)
        coordinator.navigateBackward()
        coordinator.navigateForward()

        for index in 0 ..< AppStore.searchResultsLimit {
            store.setSearchResults(emptySearchResults, for: "new-\(index)")
        }
        coordinator.invalidateUnviewableRoutes()

        #expect(store.searchResults(for: "old") == nil)
        #expect(coordinator.current.section == .albums)
        #expect(!coordinator.back.contains { $0.query == "old" })
        #expect(!coordinator.forward.contains { $0.query == "old" })
    }

    @Test func `invalidation collapses equal routes joined by a deletion`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        let playlist = playlist(id: "playlist-a")
        store.upsertPlaylist(playlist)
        store.addPlaylistToUserLibraryById(playlist.id)

        coordinator.navigateToPlaylistSection(playlistId: playlist.id)
        coordinator.selectNavigationItem(.startpage)
        store.removePlaylistFromUserLibrary(playlist.id)
        coordinator.invalidateUnviewableRoutes()

        #expect(coordinator.current == .startpage)
        #expect(coordinator.back.isEmpty)
        #expect(!coordinator.canNavigateBackward)
    }

    @Test func `two consecutive searches are separate locations`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        store.setSearchResults(emptySearchResults, for: "a")
        store.setSearchResults(emptySearchResults, for: "b")

        coordinator.navigateToSearchResults(query: "a")
        coordinator.navigateToSearchResults(query: "b")
        coordinator.navigateBackward()
        #expect(coordinator.displayedSearchQuery == "a")
        #expect(store.searchResults(for: "a") != nil)

        coordinator.navigateForward()
        #expect(coordinator.displayedSearchQuery == "b")
        #expect(store.searchResults(for: "b") != nil)
    }

    @Test func `clearing search leaves cached results reachable by back`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        store.setSearchResults(emptySearchResults, for: "query")
        coordinator.navigateToSearchResults(query: "query")

        // Clearing the field leaves Search Results but does not evict its cache.
        coordinator.selectNavigationItem(.startpage)
        coordinator.navigateBackward()

        #expect(coordinator.displayedSearchQuery == "query")
        #expect(store.searchResults(for: "query") != nil)
    }

    @Test func `reopening search results uses the last displayed query`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        store.setSearchResults(emptySearchResults, for: "a")
        store.setSearchResults(emptySearchResults, for: "b")
        coordinator.navigateToSearchResults(query: "a")
        coordinator.navigateToSearchResults(query: "b")
        coordinator.navigateBackward()
        coordinator.selectNavigationItem(.albums)

        coordinator.selectNavigationItem(.searchResults)

        #expect(coordinator.displayedSearchQuery == "a")
    }

    @Test func `search results cache is bounded and evicted routes are invalidated`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)

        for index in 0 ... AppStore.searchResultsLimit {
            let query = "query-\(index)"
            store.setSearchResults(emptySearchResults, for: query)
            coordinator.navigateToSearchResults(query: query)
        }
        coordinator.invalidateUnviewableRoutes()

        #expect(store.searchResultsByQuery.count == AppStore.searchResultsLimit)
        #expect(store.searchResults(for: "query-0") == nil)
        #expect(!coordinator.back.contains { $0.query == "query-0" })
        #expect(coordinator.displayedSearchQuery == "query-\(AppStore.searchResultsLimit)")
    }

    @Test func `library membership does not change route identity`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)
        let album = album(id: "album-a", name: "Album")
        store.upsertAlbum(album)
        coordinator.navigateToAlbumSection(albumId: album.id)
        let route = coordinator.current
        let historyCount = coordinator.back.count

        #expect(coordinator.viewingAlbumId == album.id)
        store.addAlbumToUserLibrary(album.id)
        coordinator.selectAlbum(album.id)

        #expect(coordinator.current == route)
        #expect(coordinator.back.count == historyCount)
        #expect(coordinator.viewingAlbumId == nil)
    }

    @Test func `album deep link applies its route directly`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.navigateToAlbumSection(albumId: "album-a")
        #expect(coordinator.current == Route(section: .albums, selection: .album(id: "album-a"), query: nil, path: []))
    }

    @Test func `artist deep link applies its route directly`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.navigateToArtistSection(artistId: "artist-a")
        #expect(coordinator.current == Route(section: .artists, selection: .artist(id: "artist-a"), query: nil, path: []))
    }

    @Test func `playlist deep link applies its route directly`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.navigateToPlaylistSection(playlistId: "playlist-a")
        #expect(coordinator.current == Route(section: .playlists, selection: .playlist(id: "playlist-a"), query: nil, path: []))
    }

    @Test func `queue deep link applies its route directly`() {
        let coordinator = NavigationCoordinator(store: AppStore())
        coordinator.navigateToQueue()
        #expect(coordinator.current == Route(section: .queue, selection: nil, query: nil, path: []))
    }

    private var emptySearchResults: SearchResults {
        SearchResults(albums: [], artists: [], playlists: [], tracks: [])
    }

    private func album(id: String, name: String) -> Album {
        Album(
            id: id,
            name: name,
            uri: "spotify:album:\(id)",
            images: .empty,
            releaseDate: nil,
            albumType: "album",
            externalUrl: nil,
            artistId: nil,
            artistName: "Artist",
            detailsLoaded: true,
        )
    }

    private func playlist(id: String) -> Playlist {
        Playlist(
            id: id,
            name: "Playlist",
            description: nil,
            images: .empty,
            uri: "spotify:playlist:\(id)",
            isPublic: true,
            ownerId: "owner",
            ownerName: "Owner",
        )
    }
}
