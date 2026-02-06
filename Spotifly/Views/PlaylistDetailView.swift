//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist with track list, using normalized store
//

import SwiftUI
import UniformTypeIdentifiers

struct PlaylistDetailView: View {
    /// ID is always required (either passed directly or derived from playlist object)
    let playlistId: String

    /// Optional pre-loaded playlist (avoids network request if already have data)
    private let initialPlaylist: Playlist?

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var playlist: Playlist?
    @State private var isLoadingPlaylist = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showEditDetailsDialog = false
    @State private var showDeleteConfirmation = false
    @State private var showUnfollowConfirmation = false
    @State private var editingPlaylistName = ""
    @State private var editingPlaylistDescription = ""
    @State private var playlistName: String = ""
    @State private var playlistDescription: String = ""

    // Drag-drop state
    @State private var draggedTrackId: String?
    @State private var draggedFromIndex: Int?

    /// Initialize with a playlist ID (fetches playlist data)
    init(playlistId: String, playbackViewModel: PlaybackViewModel) {
        self.playlistId = playlistId
        initialPlaylist = nil
        self.playbackViewModel = playbackViewModel
    }

    /// Initialize with a pre-loaded playlist (avoids network request)
    init(playlist: Playlist, playbackViewModel: PlaybackViewModel) {
        playlistId = playlist.id
        initialPlaylist = playlist
        self.playbackViewModel = playbackViewModel
    }

    /// Tracks from the store for this playlist
    private var tracks: [Track] {
        guard let storedPlaylist = store.playlists[playlistId] else { return [] }
        return storedPlaylist.trackIds.compactMap { store.tracks[$0] }
    }

    /// Whether the current user owns this playlist
    private var isOwner: Bool {
        playlist?.ownerId == store.userId
    }

    /// Whether this playlist is in the user's library
    private var isInLibrary: Bool {
        store.userPlaylistIds.contains(playlistId)
    }

    var body: some View {
        Group {
            if let playlist {
                playlistContent(playlist)
            } else if isLoadingPlaylist {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Button("action.try_again") {
                        Task { await loadPlaylist() }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(playlist?.name ?? "")
        .task(id: playlistId) {
            // Use initial playlist if provided, otherwise fetch
            if let initialPlaylist {
                playlist = initialPlaylist
                playlistName = initialPlaylist.name
                playlistDescription = initialPlaylist.description ?? ""
            } else {
                await loadPlaylist()
            }
            await loadTracks()
        }
        .onChange(of: playlistId) {
            if let playlist {
                playlistName = playlist.name
                playlistDescription = playlist.description ?? ""
            }
        }
        .alert("playlist.edit_details.title", isPresented: $showEditDetailsDialog) {
            TextField("playlist.edit_details.name", text: $editingPlaylistName)
            TextField("playlist.edit_details.description", text: $editingPlaylistDescription)
            Button("action.cancel", role: .cancel) {
                editingPlaylistName = ""
                editingPlaylistDescription = ""
            }
            Button("playlist.edit_details.save") {
                savePlaylistDetails()
            }
            .disabled(editingPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("playlist.edit_details.message")
        }
        .alert("playlist.delete.title", isPresented: $showDeleteConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("playlist.delete.action", role: .destructive) {
                deletePlaylist()
            }
        } message: {
            Text("playlist.delete.message \(playlistName)")
        }
        .alert("playlist.unfollow.title", isPresented: $showUnfollowConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("playlist.unfollow.action", role: .destructive) {
                unfollowPlaylist()
            }
        } message: {
            Text("playlist.unfollow.message \(playlistName)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPlaylistEditDetails)) { notification in
            if let notificationPlaylistId = notification.object as? String, notificationPlaylistId == playlistId {
                editingPlaylistName = playlistName
                editingPlaylistDescription = playlistDescription
                showEditDetailsDialog = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPlaylistDeleteConfirmation)) { notification in
            if let notificationPlaylistId = notification.object as? String, notificationPlaylistId == playlistId {
                showDeleteConfirmation = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPlaylistUnfollowConfirmation)) { notification in
            if let notificationPlaylistId = notification.object as? String, notificationPlaylistId == playlistId {
                showUnfollowConfirmation = true
            }
        }
    }

    private func playlistContent(_ playlist: Playlist) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                playlistHeader(playlist)
                trackListSection
            }
        }
    }

    // MARK: - Subviews

    private func playlistHeader(_ playlist: Playlist) -> some View {
        VStack(spacing: 16) {
            playlistArtwork(playlist)
            playlistMetadata(playlist)
            playlistActions()
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private func playlistArtwork(_ playlist: Playlist) -> some View {
        if let imageURL = playlist.imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: 200, height: 200)
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 200)
                        .cornerRadius(8)
                        .shadow(radius: 10)
                case .failure:
                    playlistArtworkPlaceholder
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            playlistArtworkPlaceholder
        }
    }

    private var playlistArtworkPlaceholder: some View {
        Image(systemName: "music.note.list")
            .font(.system(size: 60))
            .frame(width: 200, height: 200)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(8)
    }

    private func playlistMetadata(_ playlist: Playlist) -> some View {
        VStack(spacing: 8) {
            Text(playlistName)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            if !playlistDescription.isEmpty {
                Text(playlistDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                Text(String(format: String(localized: "metadata.by_owner"), playlist.ownerName))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text("metadata.separator")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                // Use actual track count once loaded, otherwise fall back to playlist metadata
                Text(String(format: String(localized: "metadata.tracks"), tracks.isEmpty ? playlist.trackCount : tracks.count))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                if !tracks.isEmpty {
                    Text("metadata.separator")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Text(totalDuration(of: tracks))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func playlistActions() -> some View {
        Button {
            playAllTracks()
        } label: {
            Label("playback.play_playlist", systemImage: "play.fill")
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(tracks.isEmpty)
    }

    @ViewBuilder
    private var trackListSection: some View {
        if isLoading {
            ProgressView("loading.tracks")
                .padding()
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .padding()
        } else if !tracks.isEmpty {
            normalTrackList
        }
    }

    private var normalTrackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                trackRowView(track: track, index: index)

                if index < tracks.count - 1 {
                    Divider()
                        .padding(.leading, 94)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.bottom, 100)
    }

    @ViewBuilder
    private func trackRowView(track: Track, index: Int) -> some View {
        let row = TrackRow(
            track: track,
            index: index,
            currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
            playbackViewModel: playbackViewModel,
            currentSection: .playlists,
            selectionId: playlistId,
        )

        if isOwner {
            row
                .opacity(draggedTrackId == track.id ? 0.5 : 1.0)
                .onDrag {
                    draggedTrackId = track.id
                    // Capture original index BEFORE any optimistic updates
                    if let playlist = store.playlists[playlistId] {
                        draggedFromIndex = playlist.trackIds.firstIndex(of: track.id)
                    }
                    return NSItemProvider(object: track.id as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: PlaylistReorderDropDelegate(
                        targetTrackId: track.id,
                        playlistId: playlistId,
                        draggedTrackId: $draggedTrackId,
                        draggedFromIndex: $draggedFromIndex,
                        store: store,
                        playlistService: playlistService,
                        session: session,
                    ),
                )
        } else {
            row
        }
    }

    private func deletePlaylist() {
        Task {
            do {
                let token = await session.validAccessToken()
                try await playlistService.deletePlaylist(
                    playlistId: playlistId,
                    accessToken: token,
                )
                // Navigate away from the deleted playlist
                navigationCoordinator.clearPlaylistSelection()
            } catch {
                errorMessage = String(localized: "error.delete_playlist \(error.localizedDescription)")
            }
        }
    }

    private func unfollowPlaylist() {
        Task {
            do {
                let token = await session.validAccessToken()
                // Uses the same API endpoint as delete - it's "unfollow" for both
                try await playlistService.deletePlaylist(
                    playlistId: playlistId,
                    accessToken: token,
                )
                // Navigate away from the unfollowed playlist
                navigationCoordinator.clearPlaylistSelection()
            } catch {
                errorMessage = String(localized: "error.unfollow_playlist \(error.localizedDescription)")
            }
        }
    }

    private func savePlaylistDetails() {
        let trimmedName = editingPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        Task {
            do {
                let token = await session.validAccessToken()
                try await playlistService.updatePlaylistDetails(
                    playlistId: playlistId,
                    name: trimmedName,
                    description: editingPlaylistDescription,
                    accessToken: token,
                )
                playlistName = trimmedName
                playlistDescription = editingPlaylistDescription
            } catch {
                errorMessage = String(localized: "error.update_playlist \(error.localizedDescription)")
            }
            editingPlaylistName = ""
            editingPlaylistDescription = ""
        }
    }

    private func loadPlaylist() async {
        isLoadingPlaylist = true
        errorMessage = nil

        let token = await session.validAccessToken()
        do {
            let playlistEntity = try await playlistService.fetchPlaylistDetails(
                playlistId: playlistId,
                accessToken: token,
            )
            playlist = playlistEntity
            playlistName = playlistEntity.name
            playlistDescription = playlistEntity.description ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingPlaylist = false
    }

    private func loadTracks() async {
        // Reset state when loading new playlist
        if let playlist {
            playlistName = playlist.name
            playlistDescription = playlist.description ?? ""
        }
        isLoading = true
        errorMessage = nil

        do {
            let token = await session.validAccessToken()
            // Load tracks via service (updates store)
            _ = try await playlistService.getPlaylistTracks(
                playlistId: playlistId,
                accessToken: token,
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func playAllTracks() {
        guard let playlist else { return }
        Task {
            let token = await session.validAccessToken()
            // Use playlist URI to load via Spirc.load(LoadRequest::from_context_uri())
            // This properly loads the playlist context instead of individual tracks
            await playbackViewModel.play(uriOrUrl: playlist.uri, accessToken: token)
        }
    }
}

// MARK: - Drag and Drop for Playlist Reordering

/// Drop delegate for reordering tracks in a playlist
struct PlaylistReorderDropDelegate: DropDelegate {
    let targetTrackId: String
    let playlistId: String
    @Binding var draggedTrackId: String?
    @Binding var draggedFromIndex: Int?
    let store: AppStore
    let playlistService: PlaylistService
    let session: SpotifySession

    func performDrop(info _: DropInfo) -> Bool {
        guard draggedTrackId != nil else { return false }

        // Use the ORIGINAL index captured when drag started (before optimistic updates)
        guard let originalFromIndex = draggedFromIndex else {
            draggedTrackId = nil
            draggedFromIndex = nil
            return false
        }

        // Get current track order to find where the target track ended up
        guard let playlist = store.playlists[playlistId] else {
            draggedTrackId = nil
            draggedFromIndex = nil
            return false
        }

        // Find the current index of the target track (this is the drop position)
        guard let currentToIndex = playlist.trackIds.firstIndex(of: targetTrackId) else {
            draggedTrackId = nil
            draggedFromIndex = nil
            return true
        }

        // Don't make API call if dropped in same position
        guard originalFromIndex != currentToIndex else {
            draggedTrackId = nil
            draggedFromIndex = nil
            return true
        }

        // Call the API with the ORIGINAL from index
        Task {
            let token = await session.validAccessToken()
            do {
                try await playlistService.reorderPlaylistTracks(
                    playlistId: playlistId,
                    rangeStart: originalFromIndex,
                    insertBefore: currentToIndex > originalFromIndex ? currentToIndex + 1 : currentToIndex,
                    accessToken: token,
                )
            } catch {
                debugLog("PlaylistReorder", "Failed to reorder: \(error)")
                // Revert the optimistic update on failure by reloading
                _ = try? await playlistService.getPlaylistTracks(
                    playlistId: playlistId,
                    accessToken: token,
                )
            }
        }

        draggedTrackId = nil
        draggedFromIndex = nil
        return true
    }

    func dropEntered(info _: DropInfo) {
        guard let draggedId = draggedTrackId,
              let playlist = store.playlists[playlistId]
        else { return }

        let trackIds = playlist.trackIds

        guard let fromIndex = trackIds.firstIndex(of: draggedId),
              let toIndex = trackIds.firstIndex(of: targetTrackId),
              fromIndex != toIndex
        else { return }

        // Optimistically update the store for visual feedback
        withAnimation(.default) {
            store.movePlaylistTrack(
                playlistId: playlistId,
                fromIndex: fromIndex,
                toIndex: toIndex,
            )
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        // Keep draggedTrackId until performDrop
    }
}
