//
//  SearchResultsView.swift
//  Spotifly
//
//  Displays search results grouped by type
//

import SwiftUI

struct SearchResultsView: View {
    let searchResults: SearchResults
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(AppStore.self) private var store
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(TrackService.self) private var trackService

    @State private var showAllTracks = false

    var body: some View {
        List {
            // Tracks section
            if !searchResults.tracks.isEmpty {
                Section {
                    let displayedTracks = showAllTracks ? searchResults.tracks : Array(searchResults.tracks.prefix(5))
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track.toTrackRowData(),
                            index: index,
                            currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                            playbackViewModel: playbackViewModel,
                        )
                        .listRowInsets(EdgeInsets())
                    }

                    if searchResults.tracks.count > 5 {
                        Button {
                            showAllTracks.toggle()
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
                    }
                } header: {
                    Text("section.tracks")
                }
            }

            // Albums section
            if !searchResults.albums.isEmpty {
                Section {
                    ForEach(store.expandedSearchAlbums ? searchResults.albums : Array(searchResults.albums.prefix(10))) { album in
                        Button {
                            navigationCoordinator.navigateToAlbum(albumId: album.id)
                        } label: {
                            HStack(spacing: 12) {
                                if let imageURL = album.imageURL {
                                    AsyncImage(url: imageURL) { phase in
                                        switch phase {
                                        case .empty:
                                            ProgressView()
                                                .frame(width: 50, height: 50)
                                        case let .success(image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 50, height: 50)
                                                .cornerRadius(4)
                                        case .failure:
                                            Image(systemName: "music.note")
                                                .frame(width: 50, height: 50)
                                                .background(Color.gray.opacity(0.2))
                                                .cornerRadius(4)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    Image(systemName: "music.note")
                                        .frame(width: 50, height: 50)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(4)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(album.artistName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        Text(String(format: String(localized: "metadata.tracks"), album.totalTracks))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        if let duration = album.formattedDuration {
                                            Text("metadata.separator")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(duration)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text("metadata.separator")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        Text(album.releaseDate)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if searchResults.albums.count > 10 {
                        Button {
                            store.expandedSearchAlbums.toggle()
                        } label: {
                            HStack {
                                Text(store.expandedSearchAlbums ? "action.show_less" : "action.show_more")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: store.expandedSearchAlbums ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                            }
                            .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("section.albums")
                }
            }

            // Artists section
            if !searchResults.artists.isEmpty {
                Section {
                    ForEach(store.expandedSearchArtists ? searchResults.artists : Array(searchResults.artists.prefix(10))) { artist in
                        Button {
                            navigationCoordinator.navigateToArtist(artistId: artist.id)
                        } label: {
                            HStack(spacing: 12) {
                                if let imageURL = artist.imageURL {
                                    AsyncImage(url: imageURL) { phase in
                                        switch phase {
                                        case .empty:
                                            ProgressView()
                                                .frame(width: 50, height: 50)
                                        case let .success(image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 50, height: 50)
                                                .clipShape(Circle())
                                        case .failure:
                                            Image(systemName: "person.circle.fill")
                                                .resizable()
                                                .frame(width: 50, height: 50)
                                                .foregroundStyle(.gray.opacity(0.3))
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .resizable()
                                        .frame(width: 50, height: 50)
                                        .foregroundStyle(.gray.opacity(0.3))
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if !artist.genres.isEmpty {
                                        Text(artist.genres.prefix(2).joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(String(format: String(localized: "metadata.followers"), formatFollowers(artist.followers)))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if searchResults.artists.count > 10 {
                        Button {
                            store.expandedSearchArtists.toggle()
                        } label: {
                            HStack {
                                Text(store.expandedSearchArtists ? "action.show_less" : "action.show_more")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: store.expandedSearchArtists ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                            }
                            .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("section.artists")
                }
            }

            // Playlists section
            if !searchResults.playlists.isEmpty {
                Section {
                    ForEach(store.expandedSearchPlaylists ? searchResults.playlists : Array(searchResults.playlists.prefix(10))) { playlist in
                        Button {
                            navigationCoordinator.navigateToPlaylist(playlist)
                        } label: {
                            HStack(spacing: 12) {
                                if let imageURL = playlist.imageURL {
                                    AsyncImage(url: imageURL) { phase in
                                        switch phase {
                                        case .empty:
                                            ProgressView()
                                                .frame(width: 50, height: 50)
                                        case let .success(image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 50, height: 50)
                                                .cornerRadius(4)
                                        case .failure:
                                            Image(systemName: "music.note.list")
                                                .frame(width: 50, height: 50)
                                                .background(Color.gray.opacity(0.2))
                                                .cornerRadius(4)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    Image(systemName: "music.note.list")
                                        .frame(width: 50, height: 50)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(4)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if let description = playlist.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 4) {
                                        Text(String(format: String(localized: "metadata.by_owner"), playlist.ownerName))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        Text("metadata.separator")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        Text(String(format: String(localized: "metadata.tracks"), playlist.trackCount))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        if let duration = playlist.formattedDuration {
                                            Text("metadata.separator")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(duration)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }

                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if searchResults.playlists.count > 10 {
                        Button {
                            store.expandedSearchPlaylists.toggle()
                        } label: {
                            HStack {
                                Text(store.expandedSearchPlaylists ? "action.show_less" : "action.show_more")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: store.expandedSearchPlaylists ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                            }
                            .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("section.playlists")
                }
            }
        }
        .listStyle(.sidebar)
        .task(id: searchResults.tracks.map(\.id).joined()) {
            // Check favorite status for all search tracks
            let token = await session.validAccessToken()
            let trackIds = searchResults.tracks.map(\.id)
            try? await trackService.checkFavoriteStatuses(trackIds: trackIds, accessToken: token)
        }
    }

    private func formatFollowers(_ count: Int) -> String {
        if count >= 1_000_000 {
            String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1000 {
            String(format: "%.1fK", Double(count) / 1000.0)
        } else {
            "\(count)"
        }
    }
}
