//
//  PlaylistsListView.swift
//  Spotifly
//
//  Displays user's playlists using normalized store
//

import SwiftUI

struct PlaylistsListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var errorMessage: String?

    /// The ephemeral playlist being viewed (if not in user's library)
    private var ephemeralPlaylist: Playlist? {
        guard let viewingId = navigationCoordinator.viewingPlaylistId,
              !store.userPlaylistIds.contains(viewingId),
              let playlist = store.playlists[viewingId]
        else {
            return nil
        }
        return playlist
    }

    /// Whether we have content to show (either ephemeral playlist or user playlists)
    private var hasContent: Bool {
        ephemeralPlaylist != nil || !store.userPlaylists.isEmpty
    }

    var body: some View {
        Group {
            if store.playlistsPagination.isLoading, !hasContent {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.playlists")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_playlists")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadPlaylists(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("empty.no_playlists")
                        .font(.headline)
                    Text("empty.no_playlists.description")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Back button when navigated from another section
                        if ephemeralPlaylist != nil, let backTitle = navigationCoordinator.backNavigationTitle {
                            Button {
                                navigationCoordinator.navigateBackward()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.caption.weight(.semibold))
                                    Text("nav.back_to \(backTitle)")
                                        .font(.subheadline)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 8)
                        }

                        // Ephemeral "Currently Viewing" section
                        if let playlist = ephemeralPlaylist {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("nav.currently_viewing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                PlaylistRow(
                                    playlist: playlist,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: navigationCoordinator.selectedPlaylistId == playlist.id,
                                    onSelect: {
                                        navigationCoordinator.selectedPlaylistId = playlist.id
                                    },
                                )
                            }

                            if !store.userPlaylists.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("nav.your_library")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        }

                        ForEach(store.userPlaylists.enumerated(), id: \.element.id) { index, playlist in
                            VStack(spacing: 0) {
                                PlaylistRow(
                                    playlist: playlist,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: navigationCoordinator.selectedPlaylistId == playlist.id,
                                    onSelect: {
                                        // Clear ephemeral state when user selects a library playlist
                                        navigationCoordinator.viewingPlaylistId = nil
                                        navigationCoordinator.selectedPlaylistId = playlist.id
                                    },
                                )

                                if index < store.userPlaylists.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }

                        // Load more indicator
                        if store.playlistsPagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMorePlaylists()
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadPlaylists(forceRefresh: true)
                }
            }
        }
        .task {
            if store.userPlaylists.isEmpty, !store.playlistsPagination.isLoading {
                await loadPlaylists()
            }
            // Always sync selection with viewing playlist ID (handles navigation from other sections)
            if let viewingId = navigationCoordinator.viewingPlaylistId {
                navigationCoordinator.selectedPlaylistId = viewingId
            } else if navigationCoordinator.selectedPlaylistId == nil, let first = store.userPlaylists.first {
                // No ephemeral playlist, select first user playlist
                navigationCoordinator.selectedPlaylistId = first.id
            }
        }
        .onChange(of: navigationCoordinator.viewingPlaylistId) { _, newId in
            // Auto-select the ephemeral playlist when it's set
            if let id = newId {
                navigationCoordinator.selectedPlaylistId = id
            }
        }
        .onChange(of: store.userPlaylists) { _, playlists in
            if navigationCoordinator.selectedPlaylistId == nil, ephemeralPlaylist == nil, let first = playlists.first {
                navigationCoordinator.selectedPlaylistId = first.id
            }
        }
    }

    private func loadPlaylists(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            let token = await session.validAccessToken()
            try await playlistService.loadUserPlaylists(
                accessToken: token,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMorePlaylists() async {
        do {
            let token = await session.validAccessToken()
            try await playlistService.loadMorePlaylists(accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @Bindable var playbackViewModel: PlaybackViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(SpotifySession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    private let imageSize: CGFloat = 36

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // Playlist image
                if let url = playlist.images.url(for: imageSize, scale: displayScale) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            playlistPlaceholder
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: imageSize, height: imageSize)
                                .clipShape(.rect(cornerRadius: 4))
                        case .failure:
                            playlistPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    playlistPlaceholder
                }

                // Playlist name
                Text(playlist.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            if isHovering {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        await playbackViewModel.play(uriOrUrl: playlist.uri, accessToken: token)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(playbackViewModel.isLoading)
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var playlistPlaceholder: some View {
        Image(systemName: "music.note.list")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: imageSize, height: imageSize)
            .background(Color.gray.opacity(0.15))
            .clipShape(.rect(cornerRadius: 4))
    }
}
