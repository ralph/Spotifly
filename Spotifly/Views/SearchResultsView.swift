//
//  SearchResultsView.swift
//  Spotifly
//
//  Displays search results with horizontal scrolling sections
//

import SwiftUI

struct SearchResultsView: View {
    let searchResults: SearchResults
    @Environment(AppStore.self) private var store
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(TrackService.self) private var trackService

    // The results as the tables hold them now. An id the tables no longer hold, such as a
    // playlist deleted since the search, is left out.

    private var tracks: [Track] {
        searchResults.trackIds.compactMap { store.tracks[$0] }
    }

    private var artists: [Artist] {
        searchResults.artistIds.compactMap { store.artists[$0] }
    }

    private var albums: [Album] {
        searchResults.albumIds.compactMap { store.albums[$0] }
    }

    private var playlists: [Playlist] {
        searchResults.playlistIds.compactMap { store.playlists[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Tracks section
                if !tracks.isEmpty {
                    tracksSection
                }

                // Artists section
                if !artists.isEmpty {
                    cardSection("section.artists") {
                        ForEach(artists) { artist in
                            ArtistCard(artist: artist)
                        }
                    }
                }

                // Albums section
                if !albums.isEmpty {
                    cardSection("section.albums") {
                        ForEach(albums) { album in
                            AlbumCard(album: album)
                        }
                    }
                }

                // Playlists section
                if !playlists.isEmpty {
                    cardSection("section.playlists") {
                        ForEach(playlists) { playlist in
                            PlaylistCard(playlist: playlist)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .task(id: searchResults.trackIds) {
            // Check favorite status for all search tracks
            await trackService.ensureFavoriteStatuses(trackIds: searchResults.trackIds)
        }
    }

    // MARK: - Tracks Section

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("section.tracks")
                    .font(.headline)

                Spacer()

                if tracks.count > 5 {
                    Button {
                        navigationCoordinator.push(.searchTracks(ids: searchResults.trackIds))
                    } label: {
                        HStack(spacing: 4) {
                            Text(localizedNumberString("show_all.tracks", tracks.count))
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

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(tracks) { track in
                        TrackCard(track: track)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Card Sections

    /// A heading over a horizontal row of cards — the shape three of the four sections have
    /// exactly. Tracks keeps its own because its heading also carries the "show all" link.
    private func cardSection(
        _ title: LocalizedStringKey,
        @ViewBuilder cards: () -> some View,
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    cards()
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}
