//
//  SearchResultsView.swift
//  Spotifly
//
//  Displays search results with horizontal scrolling sections
//

import SwiftUI

struct SearchResultsView: View {
    let searchResults: SearchResults
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(TrackService.self) private var trackService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Tracks section
                if !searchResults.tracks.isEmpty {
                    tracksSection
                }

                // Artists section
                if !searchResults.artists.isEmpty {
                    artistsSection
                }

                // Albums section
                if !searchResults.albums.isEmpty {
                    albumsSection
                }

                // Playlists section
                if !searchResults.playlists.isEmpty {
                    playlistsSection
                }
            }
            .padding(.vertical)
        }
        .task(id: searchResults.tracks.map(\.id).joined()) {
            // Check favorite status for all search tracks
            let token = await session.validAccessToken()
            let trackIds = searchResults.tracks.map(\.id)
            try? await trackService.checkFavoriteStatuses(trackIds: trackIds, accessToken: token)
        }
    }

    // MARK: - Tracks Section

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("section.tracks")
                    .font(.headline)

                Spacer()

                if searchResults.tracks.count > 5 {
                    NavigationLink(value: NavigationDestination.searchTracks(tracks: searchResults.tracks)) {
                        HStack(spacing: 4) {
                            Text(String(format: String(localized: "show_all.tracks"), searchResults.tracks.count))
                                .font(.subheadline)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                        }
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(searchResults.tracks) { track in
                        TrackCard(track: track, playbackViewModel: playbackViewModel)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Artists Section

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("section.artists")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(searchResults.artists) { artist in
                        ArtistCard(artist: artist)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("section.albums")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(searchResults.albums) { album in
                        AlbumCard(album: album)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Playlists Section

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("section.playlists")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(searchResults.playlists) { playlist in
                        PlaylistCard(playlist: playlist)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
