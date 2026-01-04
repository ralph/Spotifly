//
//  StartpageView.swift
//  Spotifly
//
//  Startpage with playback controls and track lookup
//

import AppKit
import SwiftUI

struct StartpageView: View {
    @Environment(SpotifySession.self) private var session
    @Bindable var trackViewModel: TrackLookupViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    @Bindable var recentlyPlayedViewModel: RecentlyPlayedViewModel
    @Binding var showingAllRecentTracks: Bool

    @State private var versionTapCount = 0
    @State private var showTokenInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Compact Spotify URI Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("playback.play_content")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField("playback.uri_placeholder", text: $trackViewModel.spotifyURI)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                if !trackViewModel.spotifyURI.isEmpty {
                                    Task {
                                        await playbackViewModel.play(uriOrUrl: trackViewModel.spotifyURI, accessToken: session.accessToken)
                                    }
                                }
                            }

                        if !trackViewModel.spotifyURI.isEmpty {
                            Button {
                                trackViewModel.clearInput()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Button("action.play") {
                            Task {
                                await playbackViewModel.play(uriOrUrl: trackViewModel.spotifyURI, accessToken: session.accessToken)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(trackViewModel.spotifyURI.isEmpty || playbackViewModel.isLoading)
                    }

                    if let error = playbackViewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.top)

                Divider()

                // Recently Played Section
                if recentlyPlayedViewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView("loading.recently_played")
                        Spacer()
                    }
                    .padding()
                } else if let error = recentlyPlayedViewModel.errorMessage {
                    Text(String(format: String(localized: "error.load_recently_played"), error))
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        // Recently Played Tracks (top 5 with "show more" button)
                        if !recentlyPlayedViewModel.recentTracks.isEmpty {
                            RecentTracksSection(
                                tracks: Array(recentlyPlayedViewModel.recentTracks.prefix(5)),
                                showingAllTracks: $showingAllRecentTracks,
                                playbackViewModel: playbackViewModel,
                            )
                        }

                        // Recently Played Content (mixed albums, artists, playlists)
                        if !recentlyPlayedViewModel.recentItems.isEmpty {
                            RecentContentSection(
                                items: recentlyPlayedViewModel.recentItems,
                            )
                        }
                    }
                }

                // Version Section
                VStack(spacing: 12) {
                    Divider()

                    Button {
                        versionTapCount += 1
                        if versionTapCount >= 7 {
                            showTokenInfo = true
                            // Auto-hide after 10 seconds
                            Task {
                                try? await Task.sleep(for: .seconds(10))
                                showTokenInfo = false
                                versionTapCount = 0
                            }
                        }
                    } label: {
                        Text("Version \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)

                    if showTokenInfo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("version.oauth_token")
                                .font(.caption)
                                .fontWeight(.semibold)

                            HStack(spacing: 8) {
                                Text(session.accessToken)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)

                                Button {
                                    copyTokenToClipboard()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .help("action.copy_token")
                            }

                            Text(String(format: String(localized: "version.tap_count"), versionTapCount))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom)
            }
        }
        .task {
            await recentlyPlayedViewModel.loadRecentlyPlayed(accessToken: session.accessToken)
        }
        .startpageShortcuts(
            recentlyPlayedViewModel: recentlyPlayedViewModel,
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private func copyTokenToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.accessToken, forType: .string)
    }
}

// MARK: - Recently Played Sections

struct RecentTracksSection: View {
    let tracks: [SearchTrack]
    @Binding var showingAllTracks: Bool
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session

    @State private var favoriteStatuses: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_played.tracks")
                .font(.headline)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track.toTrackRowData(),
                        index: index,
                        currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                        playbackViewModel: playbackViewModel,
                        accessToken: session.accessToken,
                        initialFavorited: favoriteStatuses[track.id],
                        onFavoriteChanged: { isFavorited in
                            favoriteStatuses[track.id] = isFavorited
                        },
                    )

                    if track.id != tracks.last?.id {
                        Divider()
                            .padding(.leading, 94)
                    }
                }

                // Show more button
                Button {
                    showingAllTracks = true
                } label: {
                    HStack {
                        Text("recently_played.show_more")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
        }
        .task(id: tracks.map(\.id)) {
            await batchCheckFavorites()
        }
    }

    private func batchCheckFavorites() async {
        let trackIds = tracks.map(\.id)
        guard !trackIds.isEmpty else { return }

        do {
            let statuses = try await SpotifyAPI.checkSavedTracks(
                accessToken: session.accessToken,
                trackIds: trackIds,
            )
            favoriteStatuses = statuses
        } catch {
            // Silently fail - rows will show unfavorited
        }
    }
}

struct RecentContentSection: View {
    let items: [RecentItem]
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_played.content")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        switch item {
                        case let .album(album):
                            RecentAlbumCard(album: album) {
                                navigationCoordinator.navigateToAlbum(
                                    albumId: album.id,
                                    accessToken: session.accessToken,
                                )
                            }

                        case let .artist(artist):
                            RecentArtistCard(artist: artist) {
                                navigationCoordinator.navigateToArtist(
                                    artistId: artist.id,
                                    accessToken: session.accessToken,
                                )
                            }

                        case let .playlist(playlist):
                            RecentPlaylistCard(playlist: playlist) {
                                navigationCoordinator.navigateToPlaylist(playlist)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Recent Item Cards

private struct RecentAlbumCard: View {
    let album: SearchAlbum
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                if let imageURL = album.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .cornerRadius(4)
                                .shadow(radius: 2)
                        case .failure:
                            albumPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    albumPlaceholder
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(album.artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var albumPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }
}

private struct RecentArtistCard: View {
    let artist: SearchArtist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                if let imageURL = artist.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .clipShape(Circle())
                                .shadow(radius: 2)
                        case .failure:
                            artistPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    artistPlaceholder
                }

                Text(artist.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .center)
            }
        }
        .buttonStyle(.plain)
    }

    private var artistPlaceholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary),
            )
    }
}

private struct RecentPlaylistCard: View {
    let playlist: SearchPlaylist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                if let imageURL = playlist.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .cornerRadius(4)
                                .shadow(radius: 2)
                        case .failure:
                            playlistPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    playlistPlaceholder
                }

                Text(playlist.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var playlistPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }
}
