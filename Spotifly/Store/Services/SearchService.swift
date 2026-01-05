//
//  SearchService.swift
//  Spotifly
//
//  Service for search functionality.
//  Performs searches and stores returned entities in AppStore so favorites work.
//

import Foundation

@MainActor
@Observable
final class SearchService {
    private let store: AppStore

    // Search state
    var searchResults: SearchResults?
    var isLoading = false
    var errorMessage: String?

    // Selection state
    var selectedTrack: SearchTrack?
    var selectedAlbum: SearchAlbum?
    var selectedArtist: SearchArtist?
    var selectedPlaylist: SearchPlaylist?
    var showingAllTracks = false

    // Expansion state for results sections
    var expandedAlbums = false
    var expandedArtists = false
    var expandedPlaylists = false

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Search

    func search(accessToken: String, query: String) async {
        guard !query.isEmpty else {
            searchResults = nil
            return
        }

        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let results = try await SpotifyAPI.search(
                accessToken: accessToken,
                query: query,
                types: [.track, .album, .artist, .playlist],
                limit: 20,
            )

            searchResults = results

            // Store tracks in AppStore so favorites work when displayed
            let tracks = results.tracks.map { Track(from: $0) }
            store.upsertTracks(tracks)

            // Store albums, artists, playlists for future reference
            let albums = results.albums.map { Album(from: $0) }
            store.upsertAlbums(albums)

            let artists = results.artists.map { Artist(from: $0) }
            store.upsertArtists(artists)

            let playlists = results.playlists.map { Playlist(from: $0) }
            store.upsertPlaylists(playlists)

        } catch {
            errorMessage = error.localizedDescription
            searchResults = nil
        }

        isLoading = false
    }

    // MARK: - Selection

    func showAllTracks() {
        showingAllTracks = true
        selectedTrack = nil
        selectedAlbum = nil
        selectedArtist = nil
        selectedPlaylist = nil
    }

    func selectTrack(_ track: SearchTrack) {
        selectedTrack = track
        selectedAlbum = nil
        selectedArtist = nil
        selectedPlaylist = nil
        showingAllTracks = false
    }

    func selectAlbum(_ album: SearchAlbum) {
        selectedAlbum = album
        selectedTrack = nil
        selectedArtist = nil
        selectedPlaylist = nil
        showingAllTracks = false
    }

    func selectArtist(_ artist: SearchArtist) {
        selectedArtist = artist
        selectedTrack = nil
        selectedAlbum = nil
        selectedPlaylist = nil
        showingAllTracks = false
    }

    func selectPlaylist(_ playlist: SearchPlaylist) {
        selectedPlaylist = playlist
        selectedTrack = nil
        selectedAlbum = nil
        selectedArtist = nil
        showingAllTracks = false
    }

    func clearSelection() {
        selectedTrack = nil
        selectedAlbum = nil
        selectedArtist = nil
        selectedPlaylist = nil
        showingAllTracks = false
    }

    func clearSearch() {
        searchResults = nil
        selectedTrack = nil
        selectedAlbum = nil
        selectedArtist = nil
        selectedPlaylist = nil
        showingAllTracks = false
        expandedAlbums = false
        expandedArtists = false
        expandedPlaylists = false
        errorMessage = nil
    }
}
