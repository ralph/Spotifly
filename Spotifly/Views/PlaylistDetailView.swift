//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist with track list, using normalized store
//

import SwiftUI
import UniformTypeIdentifiers

struct PlaylistDetailView: View {
    // ID is always required (either passed directly or derived from playlist object)
    let playlistId: String

    // Optional pre-loaded playlist (avoids network request if already have data)
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
    @State private var editingPlaylistName = ""
    @State private var editingPlaylistDescription = ""
    @State private var playlistName: String = ""
    @State private var playlistDescription: String = ""

    // Edit mode state
    @State private var isEditing = false
    @State private var editedTrackIds: [String] = []
    @State private var isSaving = false
    @State private var draggedTrackId: String?

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
        playlist?.ownerId == session.userId
    }

    /// Whether there are unsaved changes in edit mode
    private var hasChanges: Bool {
        guard let storedPlaylist = store.playlists[playlistId] else { return false }
        return storedPlaylist.trackIds != editedTrackIds
    }

    /// Tracks being edited (from editedTrackIds)
    private var editedTracks: [Track] {
        editedTrackIds.compactMap { store.tracks[$0] }
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
        .alert("Edit Playlist", isPresented: $showEditDetailsDialog) {
            TextField("Name", text: $editingPlaylistName)
            TextField("Description", text: $editingPlaylistDescription)
            Button("Cancel", role: .cancel) {
                editingPlaylistName = ""
                editingPlaylistDescription = ""
            }
            Button("Save") {
                savePlaylistDetails()
            }
            .disabled(editingPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Edit playlist name and description")
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

    private func playlistContent(_ playlist: Playlist) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                playlistHeader(playlist)
                trackListSection
            }
        }
        .overlay(alignment: .bottom) {
            floatingEditBar
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

            playlistContextMenu()
        }
    }

    private func playlistContextMenu() -> some View {
        Menu {
            if isOwner {
                Button {
                    enterEditMode()
                } label: {
                    Label("playlist.edit", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    editingPlaylistName = playlistName
                    editingPlaylistDescription = playlistDescription
                    showEditDetailsDialog = true
                } label: {
                    Label("Edit Details", systemImage: "pencil")
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
                editTrackRowView(track: track)

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

    private func editTrackRowView(track: Track) -> some View {
        let trackId = track.id
        return EditTrackRowFromTrack(track: track) {
            withAnimation {
                if let idx = editedTrackIds.firstIndex(of: trackId) {
                    editedTrackIds.remove(at: idx)
                }
            }
        }
        .opacity(draggedTrackId == track.id ? 0.5 : 1.0)
        .onDrag {
            draggedTrackId = track.id
            return NSItemProvider(object: track.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: TrackIdDropDelegate(
                itemId: track.id,
                items: $editedTrackIds,
                draggedItemId: $draggedTrackId,
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
                    currentSection: .playlists,
                    selectionId: playlistId,
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
                let token = await session.validAccessToken()
                try await playlistService.deletePlaylist(
                    playlistId: playlistId,
                    accessToken: token,
                )
                // Navigate away from the deleted playlist
                navigationCoordinator.clearPlaylistSelection()
            } catch {
                errorMessage = "Failed to delete playlist: \(error.localizedDescription)"
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
                errorMessage = "Failed to update playlist: \(error.localizedDescription)"
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
        Task {
            let token = await session.validAccessToken()
            await playbackViewModel.playTracks(
                tracks.map(\.uri),
                accessToken: token,
            )
        }
    }

    // MARK: - Edit Mode

    private func enterEditMode() {
        guard let storedPlaylist = store.playlists[playlistId] else { return }
        editedTrackIds = storedPlaylist.trackIds
        isEditing = true
    }

    private func cancelEditMode() {
        isEditing = false
        editedTrackIds = []
    }

    private func saveChanges() {
        guard hasChanges else { return }

        Task {
            isSaving = true

            do {
                let token = await session.validAccessToken()
                // Replace all tracks with the new order
                let newTrackUris = editedTrackIds.map { "spotify:track:\($0)" }
                try await playlistService.replacePlaylistTracks(
                    playlistId: playlistId,
                    trackUris: newTrackUris,
                    accessToken: token,
                )

                // Exit edit mode
                isEditing = false
                editedTrackIds = []
            } catch {
                errorMessage = "Failed to save changes: \(error.localizedDescription)"
            }

            isSaving = false
        }
    }
}

// MARK: - Edit Track Row (for unified Track entity)

/// Track row for edit mode using unified Track entity
struct EditTrackRowFromTrack: View {
    let track: Track
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            // Album art
            if let imageURL = track.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 40, height: 40)
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .cornerRadius(4)
                    case .failure:
                        Image(systemName: "music.note")
                            .font(.caption)
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.caption)
                    .frame(width: 40, height: 40)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(track.durationFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Delete button
            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Drag and Drop for Track IDs

/// Drop delegate for reordering tracks by ID in edit mode
struct TrackIdDropDelegate: DropDelegate {
    let itemId: String
    @Binding var items: [String]
    @Binding var draggedItemId: String?

    func performDrop(info _: DropInfo) -> Bool {
        draggedItemId = nil
        return true
    }

    func dropEntered(info _: DropInfo) {
        guard let draggedItemId,
              let fromIndex = items.firstIndex(of: draggedItemId),
              let toIndex = items.firstIndex(of: itemId),
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
        // Keep draggedItemId until performDrop
    }
}
