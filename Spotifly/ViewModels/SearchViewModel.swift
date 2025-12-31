//
//  SearchViewModel.swift
//  Spotifly
//
//  Manages search state and results
//

import SwiftUI

@MainActor
@Observable
final class SearchViewModel {
    var searchResults: SearchResults?
    var isLoading = false
    var errorMessage: String?
    var selectedTrack: SearchTrack?
    var selectedAlbum: SearchAlbum?
    var selectedArtist: SearchArtist?
    var selectedPlaylist: SearchPlaylist?

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
                limit: 20
            )

            searchResults = results
        } catch {
            errorMessage = error.localizedDescription
            searchResults = nil
        }

        isLoading = false
    }

    func clearSearch() {
        searchResults = nil
        selectedTrack = nil
        selectedAlbum = nil
        selectedArtist = nil
        selectedPlaylist = nil
        errorMessage = nil
    }

    func selectTrack(_ track: SearchTrack) {
        selectedTrack = track
        selectedAlbum = nil
        selectedArtist = nil
        selectedPlaylist = nil
    }

    func selectAlbum(_ album: SearchAlbum) {
        selectedAlbum = album
        selectedTrack = nil
        selectedArtist = nil
        selectedPlaylist = nil
    }

    func selectArtist(_ artist: SearchArtist) {
        selectedArtist = artist
        selectedTrack = nil
        selectedAlbum = nil
        selectedPlaylist = nil
    }

    func selectPlaylist(_ playlist: SearchPlaylist) {
        selectedPlaylist = playlist
        selectedTrack = nil
        selectedAlbum = nil
        selectedArtist = nil
    }
}
