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
    @Environment(AppStore.self) private var store
    @Environment(SpotifySession.self) private var session
    @Environment(TrackService.self) private var trackService

    @State private var showAllTracks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Tracks section (keeping list style for now)
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

    @ViewBuilder
    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("section.tracks")
                .font(.headline)
                .padding(.horizontal)

            let displayedTracks = showAllTracks ? searchResults.tracks : Array(searchResults.tracks.prefix(5))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track.toTrackRowData(),
                        index: index,
                        currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                        playbackViewModel: playbackViewModel,
                    )

                    if index < displayedTracks.count - 1 {
                        Divider()
                            .padding(.leading, 94)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)

            if searchResults.tracks.count > 5 {
                Button {
                    withAnimation {
                        showAllTracks.toggle()
                    }
                } label: {
                    HStack {
                        Text(showAllTracks ? "action.show_less" : String(format: String(localized: "show_all.tracks"), searchResults.tracks.count))
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: showAllTracks ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Artists Section

    @ViewBuilder
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

    @ViewBuilder
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

    @ViewBuilder
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
