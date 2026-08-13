//
//  TrackContextMenu.swift
//  Spotifly
//
//  Reusable context menu for tracks - used in TrackRow and on cards
//

import SwiftUI

/// Reusable context menu content for tracks
struct TrackContextMenu: View {
    let track: Track
    let currentSection: NavigationItem
    let selectionId: String?
    /// The playlist item this menu was opened from, where the caller knows which one.
    let itemUid: String?
    @Bindable var playbackViewModel: PlaybackViewModel

    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaylistService.self) private var playlistService

    @Binding var showNewPlaylistDialog: Bool
    var onPlaylistAdded: (() -> Void)?
    var onNavigate: (() -> Void)?

    /// Favorite status from the store
    private var isFavorited: Bool {
        store.isFavorite(track.id)
    }

    /// The row to remove, when there is one the user can remove and this menu can name.
    ///
    /// Removing is only offered inside a playlist the user owns: the menu is reused from
    /// albums, search and the queue, where "this playlist" would mean nothing, and Spotify
    /// rejects the edit for a playlist someone else owns.
    ///
    /// **The uid is required, not preferred.** Without it the menu can only say "a row holding
    /// this song", and a playlist may hold the same song twice — so the removal would land on
    /// whichever copy came first rather than the one the user right-clicked. Requiring it makes
    /// that unrepresentable instead of a fallback: the only screen that offers this is the
    /// playlist page, and it has the uid.
    private var removableItem: (playlistId: String, uid: String)? {
        guard currentSection == .playlists,
              let playlistId = selectionId,
              let itemUid,
              store.playlists[playlistId]?.ownerId == store.userId
        else {
            return nil
        }
        return (playlistId, itemUid)
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
                store: store,
                playlistService: playlistService,
                onAddToPlaylist: addToPlaylist,
            )
        } label: {
            Label("track.menu.add_to_playlist", systemImage: "music.note.list")
        }

        if let item = removableItem {
            Button(role: .destructive) {
                removeFromPlaylist(playlistId: item.playlistId, uid: item.uid)
            } label: {
                Label("track.menu.remove_from_playlist", systemImage: "minus.circle")
            }
        }

        Divider()

        Button {
            if let artistId = track.artistId {
                onNavigate?()
                navigationCoordinator.navigateToArtistSection(artistId: artistId)
            }
        } label: {
            Label("track.menu.go_to_artist", systemImage: "person.circle")
        }
        .disabled(track.artistId == nil || (currentSection == .artists && track.artistId == selectionId))

        Button {
            if let albumId = track.albumId {
                onNavigate?()
                navigationCoordinator.navigateToAlbumSection(albumId: albumId)
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
            await playbackViewModel.addToQueue(uri: track.uri)
        }
    }

    private func startSongRadio() {
        Task {
            await playbackViewModel.playRadio(trackUri: track.uri)
            onNavigate?()
            navigationCoordinator.navigateToQueue()
        }
    }

    private func toggleFavorite() {
        Task {
            do {
                try await trackService.toggleFavorite(trackId: track.id)
            } catch {
                playbackViewModel.errorMessage = "Failed to update favorite: \(error.localizedDescription)"
            }
        }
    }

    private func addToPlaylist(playlistId: String) {
        Task {
            do {
                try await playlistService.addTracksToPlaylist(
                    playlistId: playlistId,
                    trackIds: [track.id],
                )
                onPlaylistAdded?()
            } catch {
                playbackViewModel.errorMessage = "Failed to add to playlist: \(error.localizedDescription)"
            }
        }
    }

    private func removeFromPlaylist(playlistId: String, uid: String) {
        Task {
            do {
                try await playlistService.removePlaylistItems(
                    playlistId: playlistId,
                    uids: [uid],
                )
            } catch {
                playbackViewModel.errorMessage = "Failed to remove from playlist: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Convenience initializer with constant binding

extension TrackContextMenu {
    /// Initialize without playlist dialog support (for context menus)
    init(
        track: Track,
        currentSection: NavigationItem = .startpage,
        selectionId: String? = nil,
        itemUid: String? = nil,
        playbackViewModel: PlaybackViewModel,
    ) {
        self.track = track
        self.currentSection = currentSection
        self.selectionId = selectionId
        self.itemUid = itemUid
        self.playbackViewModel = playbackViewModel
        _showNewPlaylistDialog = .constant(false)
        onPlaylistAdded = nil
        onNavigate = nil
    }
}

// MARK: - Playlist Submenu Content (lazy loading)

/// A view that loads playlists on-demand when the submenu appears
private struct PlaylistSubmenuContent: View {
    let store: AppStore
    let playlistService: PlaylistService
    let onAddToPlaylist: (String) -> Void

    @State private var hasTriggeredLoad = false

    private var ownedPlaylists: [Playlist] {
        store.userPlaylists.filter { $0.ownerId == store.userId }
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
            if store.userPlaylists.isEmpty, !store.playlistsPagination.isLoading {
                try? await playlistService.loadUserPlaylists()
            }
        }
    }
}
