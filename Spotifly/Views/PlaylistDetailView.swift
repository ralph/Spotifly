//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist search result with track list
//

import SwiftUI
import UniformTypeIdentifiers

struct PlaylistDetailView: View {
    let playlist: SearchPlaylist
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(PlaylistsViewModel.self) private var playlistsViewModel
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var tracks: [PlaylistTrack] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var favoriteStatuses: [String: Bool] = [:]
    @State private var showRenameDialog = false
    @State private var showDeleteConfirmation = false
    @State private var newPlaylistName = ""
    @State private var playlistName: String

    // Edit mode state
    @State private var isEditing = false
    @State private var editedTracks: [PlaylistTrack] = []
    @State private var isSaving = false
    @State private var draggedTrack: PlaylistTrack?

    /// Whether the current user owns this playlist
    private var isOwner: Bool {
        playlist.ownerId == session.userId
    }

    /// Whether there are unsaved changes
    private var hasChanges: Bool {
        tracks.map(\.uri) != editedTracks.map(\.uri)
    }

    init(playlist: SearchPlaylist, playbackViewModel: PlaybackViewModel) {
        self.playlist = playlist
        self.playbackViewModel = playbackViewModel
        _playlistName = State(initialValue: playlist.name)
    }

    private var totalDuration: String {
        let totalMs = tracks.reduce(0) { $0 + $1.durationMs }
        let totalSeconds = totalMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(format: "%d hr %d min", hours, minutes)
        } else {
            return String(format: "%d min", minutes)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                playlistHeader
                trackListSection
            }
        }
        .overlay(alignment: .bottom) {
            floatingEditBar
        }
        .task(id: playlist.id) {
            await loadTracks()
        }
        .onChange(of: playlist.id) {
            playlistName = playlist.name
        }
        .alert("Rename Playlist", isPresented: $showRenameDialog) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {
                newPlaylistName = ""
            }
            Button("Rename") {
                renamePlaylist()
            }
            .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Enter a new name for the playlist")
        }
        .alert("Delete Playlist", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deletePlaylist()
            }
        } message: {
            Text("Are you sure you want to delete \"\(playlistName)\"? This action cannot be undone.")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var playlistHeader: some View {
        VStack(spacing: 16) {
            playlistArtwork
            playlistMetadata
            playlistActions
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private var playlistArtwork: some View {
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

    private var playlistMetadata: some View {
        VStack(spacing: 8) {
            Text(playlistName)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            if let description = playlist.description, !description.isEmpty {
                Text(description)
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
                    Text(totalDuration)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var playlistActions: some View {
        HStack(spacing: 12) {
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

            playlistContextMenu
        }
    }

    private var playlistContextMenu: some View {
        Menu {
            if isOwner {
                Button {
                    enterEditMode()
                } label: {
                    Label("playlist.edit", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    newPlaylistName = playlistName
                    showRenameDialog = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isEditing)
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
        } else if isEditing {
            editModeTrackList
        } else if !tracks.isEmpty {
            normalTrackList
        }
    }

    private var editModeTrackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(editedTracks.enumerated()), id: \.element.id) { index, track in
                editTrackRowView(track: track, index: index)

                if index < editedTracks.count - 1 {
                    Divider()
                        .padding(.leading, 94)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.bottom, 80)
    }

    private func editTrackRowView(track: PlaylistTrack, index _: Int) -> some View {
        let trackId = track.id
        return EditTrackRow(track: track) {
            withAnimation {
                if let idx = editedTracks.firstIndex(where: { $0.id == trackId }) {
                    editedTracks.remove(at: idx)
                }
            }
        }
        .opacity(draggedTrack?.id == track.id ? 0.5 : 1.0)
        .onDrag {
            draggedTrack = track
            return NSItemProvider(object: track.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: TrackDropDelegate(
                item: track,
                items: $editedTracks,
                draggedItem: $draggedTrack,
            ),
        )
    }

    private var normalTrackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
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

                if index < tracks.count - 1 {
                    Divider()
                        .padding(.leading, 94)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var floatingEditBar: some View {
        if isEditing {
            HStack(spacing: 16) {
                Button {
                    cancelEditMode()
                } label: {
                    Text("playlist.edit.cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)

                saveButton
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8)
            .padding()
        }
    }

    private var saveButton: some View {
        Button {
            saveChanges()
        } label: {
            if isSaving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("playlist.edit.saving")
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("playlist.edit.save")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(isSaving || !hasChanges)
    }

    private func deletePlaylist() {
        Task {
            do {
                try await SpotifyAPI.deletePlaylist(
                    accessToken: session.accessToken,
                    playlistId: playlist.id,
                )
                // Refresh playlists to update the sidebar
                await playlistsViewModel.refresh(accessToken: session.accessToken)
                // Navigate away from the deleted playlist
                navigationCoordinator.clearPlaylistSelection()
            } catch {
                errorMessage = "Failed to delete playlist: \(error.localizedDescription)"
            }
        }
    }

    private func renamePlaylist() {
        let trimmedName = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        Task {
            do {
                try await SpotifyAPI.renamePlaylist(
                    accessToken: session.accessToken,
                    playlistId: playlist.id,
                    newName: trimmedName,
                )
                playlistName = trimmedName
                // Refresh playlists to update the sidebar
                await playlistsViewModel.refresh(accessToken: session.accessToken)
            } catch {
                errorMessage = "Failed to rename playlist: \(error.localizedDescription)"
            }
            newPlaylistName = ""
        }
    }

    private func loadTracks() async {
        // Reset all state when loading new playlist
        tracks = []
        favoriteStatuses = [:]
        playlistName = playlist.name
        isLoading = true
        errorMessage = nil

        do {
            tracks = try await SpotifyAPI.fetchPlaylistTracks(
                accessToken: session.accessToken,
                playlistId: playlist.id,
            )

            // Batch check favorite statuses
            let trackIds = tracks.map(\.id)
            if !trackIds.isEmpty {
                favoriteStatuses = try await SpotifyAPI.checkSavedTracks(
                    accessToken: session.accessToken,
                    trackIds: trackIds,
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func playAllTracks() {
        Task {
            await playbackViewModel.playTracks(
                tracks.map(\.uri),
                accessToken: session.accessToken,
            )
        }
    }

    // MARK: - Edit Mode

    private func enterEditMode() {
        editedTracks = tracks
        isEditing = true
    }

    private func cancelEditMode() {
        isEditing = false
        editedTracks = []
    }

    private func saveChanges() {
        guard hasChanges else { return }

        Task {
            isSaving = true

            do {
                // Replace all tracks with the new order (handles both reordering and removals)
                let newTrackUris = editedTracks.map(\.uri)
                try await SpotifyAPI.replacePlaylistTracks(
                    accessToken: session.accessToken,
                    playlistId: playlist.id,
                    trackUris: newTrackUris,
                )

                // Update local state
                tracks = editedTracks
                isEditing = false
                editedTracks = []

                // Update track count in sidebar immediately
                playlistsViewModel.updateTrackCount(playlistId: playlist.id, count: tracks.count)
            } catch {
                errorMessage = "Failed to save changes: \(error.localizedDescription)"
            }

            isSaving = false
        }
    }
}

// MARK: - Drag and Drop

/// Drop delegate for reordering tracks in edit mode
struct TrackDropDelegate: DropDelegate {
    let item: PlaylistTrack
    @Binding var items: [PlaylistTrack]
    @Binding var draggedItem: PlaylistTrack?

    func performDrop(info _: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }

    func dropEntered(info _: DropInfo) {
        guard let draggedItem,
              let fromIndex = items.firstIndex(where: { $0.id == draggedItem.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }),
              fromIndex != toIndex
        else {
            return
        }

        withAnimation(.default) {
            items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        // Keep draggedItem until performDrop
    }
}
