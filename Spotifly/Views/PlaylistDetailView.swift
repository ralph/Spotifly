//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist with track list, using normalized store
//

import SwiftUI
import UniformTypeIdentifiers

struct PlaylistDetailView: View {
    let playlistId: String

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaylistService.self) private var playlistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.displayScale) private var displayScale

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showEditDetailsDialog = false
    @State private var showDeleteConfirmation = false
    @State private var showUnfollowConfirmation = false
    @State private var editingPlaylistName = ""
    @State private var editingPlaylistDescription = ""

    // Drag-drop state
    @State private var draggedTrackId: String?
    @State private var draggedFromIndex: Int?

    /// The playlist from the store — the only copy. Whatever a load puts there
    /// shows up here, including a load whose original view was torn down mid-flight.
    private var playlist: Playlist? {
        store.playlists[playlistId]
    }

    private var playlistName: String {
        playlist?.name ?? ""
    }

    private var playlistDescription: String {
        playlist?.description ?? ""
    }

    /// Tracks from the store for this playlist
    private var tracks: [Track] {
        playlist?.trackIds.compactMap { store.tracks[$0] } ?? []
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
            } else if let errorMessage {
                InlineLoadError(message: errorMessage) {
                    await loadPlaylist()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(playlistName)
        .task(id: playlistId) {
            await loadPlaylist()
        }
        .task(id: tracks.map(\.id).joined()) {
            await resolveFavoriteStatusesForTracks()
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
        if let url = playlist.images.url(for: 200, scale: displayScale) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: 200, height: 200)
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 200)
                        .clipShape(.rect(cornerRadius: 8))
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
            .clipShape(.rect(cornerRadius: 8))
    }

    private func playlistMetadata(_ playlist: Playlist) -> some View {
        VStack(spacing: 8) {
            Text(playlistName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            if !playlistDescription.isEmpty {
                Text(playlistDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                Text(localizedTextString("metadata.by_owner", playlist.ownerName))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text("metadata.separator")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                // Use actual track count once loaded, otherwise fall back to playlist metadata
                Text(localizedNumberString("metadata.tracks", tracks.isEmpty ? playlist.trackCount : tracks.count))
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
            InlineLoadError(message: errorMessage) {
                await reloadTracks()
            }
        } else if !tracks.isEmpty {
            normalTrackList
        }
    }

    private var normalTrackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tracks.enumerated(), id: \.offset) { index, track in
                trackRowView(track: track, index: index)

                if index < tracks.count - 1 {
                    Divider()
                        .padding(.leading, 94)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
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
            onDoubleTap: {
                guard let uri = playlist?.uri else { return }
                let token = await session.validAccessToken()
                await playbackViewModel.play(
                    uriOrUrl: uri,
                    trackIndex: index,
                    accessToken: token,
                )
            },
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
                        errorMessage: $errorMessage,
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
            } catch {
                errorMessage = String(localized: "error.update_playlist \(error.localizedDescription)")
            }
            editingPlaylistName = ""
            editingPlaylistDescription = ""
        }
    }

    private func resolveFavoriteStatusesForTracks() async {
        guard !tracks.isEmpty else { return }

        await trackService.ensureFavoriteStatuses(trackIds: tracks.map(\.id))
    }

    private func loadPlaylist() async {
        // Only claim to be loading when the track list is actually missing —
        // a cached playlist must not flash a spinner over its tracks.
        isLoading = playlist?.tracksLoaded != true
        errorMessage = nil

        do {
            try await playlistService.ensurePlaylistLoaded(playlistId: playlistId)
        } catch {
            // A cancellation is this view going away, not a failure: the load keeps
            // running and its result is in the store for whatever replaces us.
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    /// The track-list retry. It re-fetches unconditionally rather than going through
    /// `ensurePlaylistLoaded`, because the message it sits under can be a failed
    /// reorder rollback — where the store holds a track list that *is* loaded and
    /// wrong, so the cache-respecting call would fetch nothing.
    private func reloadTracks() async {
        isLoading = true
        errorMessage = nil

        do {
            try await playlistService.reloadPlaylistTracks(playlistId: playlistId)
        } catch {
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
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
    @Binding var errorMessage: String?
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
                // A newer reorder cancelled this one's reconciliation. It owns the
                // final order now; rolling back here would only cancel it in turn.
                guard !isCancellation(error) else { return }

                debugLog("PlaylistReorder", "Failed to reorder: \(error)")
                // Revert the optimistic update by re-fetching the real order. This
                // has to bypass the cache — the optimistic update already wrote the
                // order we are trying to undo. If even that fails, say so: the list
                // on screen is then not the one the server has.
                do {
                    try await playlistService.reloadPlaylistTracks(playlistId: playlistId)
                } catch {
                    errorMessage = String(localized: "error.reorder_tracks \(error.localizedDescription)")
                }
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
