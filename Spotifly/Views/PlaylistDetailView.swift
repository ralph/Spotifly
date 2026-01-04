//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist search result with track list
//

import SwiftUI

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

    /// Whether the current user owns this playlist
    private var isOwner: Bool {
        playlist.ownerId == session.userId
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
                // Playlist art and metadata
                VStack(spacing: 16) {
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
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 60))
                                    .frame(width: 200, height: 200)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60))
                            .frame(width: 200, height: 200)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    }

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
                            Text(String(format: String(localized: "metadata.tracks"), playlist.trackCount))
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

                    // Play All button and menu
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

                        // Context menu
                        Menu {
                            if isOwner {
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
                    }
                }
                .padding(.top, 24)

                // Track list
                if isLoading {
                    ProgressView("loading.tracks")
                        .padding()
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if !tracks.isEmpty {
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
            }
        }
        .task(id: playlist.id) {
            await loadTracks()
        }
        .onChange(of: playlist.id) {
            // Reset name when switching playlists
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
        // Clear old tracks when loading new playlist
        tracks = []
        favoriteStatuses = [:]
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
}
