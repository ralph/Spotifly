//
//  TrackContextMenu.swift
//  Spotifly
//
//  Reusable context menu for tracks - used in TrackRow and on cards
//

import SwiftUI

/// Reusable context menu content for tracks
struct TrackContextMenu: View {
    let track: TrackRowData
    let currentSection: NavigationItem
    let selectionId: String?
    @Bindable var playbackViewModel: PlaybackViewModel

    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaylistService.self) private var playlistService

    @Binding var showNewPlaylistDialog: Bool
    var onPlaylistAdded: (() -> Void)?
    var onNavigate: (() -> Void)?

    /// Favorite status from the store
    private var isFavorited: Bool {
        store.isFavorite(track.trackId)
    }

    var body: some View {
        // Single unified action - "Play Next" adds to queue (plays before context tracks)
        Button {
            addToQueue()
        } label: {
            Label("track.menu.play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            startSongRadio()
        } label: {
            Label("track.menu.start_radio", systemImage: "antenna.radiowaves.left.and.right")
        }

        Divider()

        // Favorite toggle
        Button {
            toggleFavorite()
        } label: {
            Label(
                isFavorited ? "track.menu.remove_from_favorites" : "track.menu.add_to_favorites",
                systemImage: isFavorited ? "heart.slash" : "heart",
            )
        }

        // Playlist Management Section
        Menu {
            Button {
                showNewPlaylistDialog = true
            } label: {
                Label("track.menu.add_to_new_playlist", systemImage: "plus")
            }

            PlaylistSubmenuContent(
                session: session,
                store: store,
                playlistService: playlistService,
                onAddToPlaylist: addToPlaylist,
            )
        } label: {
            Label("track.menu.add_to_playlist", systemImage: "music.note.list")
        }

        Divider()

        Button {
            if let artistId = track.artistId {
                onNavigate?()
                navigationCoordinator.navigateToArtistSection(
                    artistId: artistId,
                    from: currentSection,
                    selectionId: selectionId,
                )
            }
        } label: {
            Label("track.menu.go_to_artist", systemImage: "person.circle")
        }
        .disabled(track.artistId == nil || (currentSection == .artists && track.artistId == selectionId))

        Button {
            if let albumId = track.albumId {
                onNavigate?()
                navigationCoordinator.navigateToAlbumSection(
                    albumId: albumId,
                    from: currentSection,
                    selectionId: selectionId,
                )
            }
        } label: {
            Label("track.menu.go_to_album", systemImage: "square.stack")
        }
        .disabled(track.albumId == nil || (currentSection == .albums && track.albumId == selectionId))

        Divider()

        Button {
            copyToClipboard()
        } label: {
            Label("action.share", systemImage: "square.and.arrow.up")
        }
        .disabled(track.externalUrl == nil)
    }

    // MARK: - Actions

    private func copyToClipboard() {
        guard let externalUrl = track.externalUrl else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(externalUrl, forType: .string)
    }

    private func addToQueue() {
        Task {
            let token = await session.validAccessToken()
            await playbackViewModel.addToQueue(
                trackUri: track.uri,
                accessToken: token,
            )
        }
    }

    private func startSongRadio() {
        Task {
            do {
                let token = await session.validAccessToken()
                await playbackViewModel.initializeIfNeeded(accessToken: token)
                try SpotifyPlayer.playRadio(trackUri: track.uri)
                onNavigate?()
                navigationCoordinator.navigateToQueue()
            } catch {
                playbackViewModel.errorMessage = "Failed to start radio: \(error.localizedDescription)"
            }
        }
    }

    private func toggleFavorite() {
        Task {
            do {
                let token = await session.validAccessToken()
                try await trackService.toggleFavorite(
                    trackId: track.trackId,
                    accessToken: token,
                )
            } catch {
                playbackViewModel.errorMessage = "Failed to update favorite: \(error.localizedDescription)"
            }
        }
    }

    private func addToPlaylist(playlistId: String) {
        Task {
            do {
                let token = await session.validAccessToken()
                try await playlistService.addTracksToPlaylist(
                    playlistId: playlistId,
                    trackIds: [track.trackId],
                    accessToken: token,
                )
                onPlaylistAdded?()
            } catch {
                playbackViewModel.errorMessage = "Failed to add to playlist: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Convenience initializer with constant binding

extension TrackContextMenu {
    /// Initialize without playlist dialog support (for context menus)
    init(
        track: TrackRowData,
        currentSection: NavigationItem = .startpage,
        selectionId: String? = nil,
        playbackViewModel: PlaybackViewModel,
    ) {
        self.track = track
        self.currentSection = currentSection
        self.selectionId = selectionId
        self.playbackViewModel = playbackViewModel
        _showNewPlaylistDialog = .constant(false)
        onPlaylistAdded = nil
        onNavigate = nil
    }
}

// MARK: - Playlist Submenu Content (lazy loading)

/// A view that loads playlists on-demand when the submenu appears
private struct PlaylistSubmenuContent: View {
    let session: SpotifySession
    let store: AppStore
    let playlistService: PlaylistService
    let onAddToPlaylist: (String) -> Void

    @State private var hasTriggeredLoad = false

    private var ownedPlaylists: [Playlist] {
        store.userPlaylists.filter { $0.ownerId == session.userId }
    }

    var body: some View {
        // Loading state
        if store.playlistsPagination.isLoading, ownedPlaylists.isEmpty {
            Text("playlist.loading")
                .foregroundStyle(.secondary)
                .onAppear {
                    triggerLoadIfNeeded()
                }
        } else if ownedPlaylists.isEmpty {
            // No playlists yet - trigger load and show placeholder
            Text("playlist.loading")
                .foregroundStyle(.secondary)
                .onAppear {
                    triggerLoadIfNeeded()
                }
        } else {
            // Show playlists
            Divider()

            ForEach(ownedPlaylists) { playlist in
                Button(playlist.name) {
                    onAddToPlaylist(playlist.id)
                }
            }
        }
    }

    private func triggerLoadIfNeeded() {
        guard !hasTriggeredLoad else { return }
        hasTriggeredLoad = true

        Task {
            await session.loadUserIdIfNeeded()
            if store.userPlaylists.isEmpty, !store.playlistsPagination.isLoading {
                let token = await session.validAccessToken()
                try? await playlistService.loadUserPlaylists(accessToken: token)
            }
        }
    }
}
