//
//  TrackRow.swift
//  Spotifly
//
//  Reusable track row component for displaying tracks across different views
//

import SwiftUI

/// Data needed to display a track row
struct TrackRowData: Identifiable {
    let id: String
    let uri: String
    let name: String
    let artistName: String
    let albumArtURL: String?
    let durationMs: Int
    let trackNumber: Int? // Optional - only shown in album views
    let albumId: String? // For navigation to album
    let artistId: String? // For navigation to artist
    let externalUrl: String? // Web URL for sharing

    var durationFormatted: String {
        formatTrackTime(milliseconds: durationMs)
    }

    /// Extracts the track ID for API calls (handles both plain IDs and URIs)
    var trackId: String {
        SpotifyAPI.parseTrackURI(id) ?? id
    }
}

/// Double-tap behavior for TrackRow
enum TrackRowDoubleTapBehavior {
    case playTrack // Play just this track
}

/// Reusable track row view
struct TrackRow: View {
    let track: TrackRowData
    let showTrackNumber: Bool // Show track number instead of index
    let index: Int? // Optional index for queue
    let isCurrentTrack: Bool
    let isPlayedTrack: Bool // For queue - tracks that have already played
    @Bindable var playbackViewModel: PlaybackViewModel
    let doubleTapBehavior: TrackRowDoubleTapBehavior
    let currentSection: NavigationItem // Current sidebar section (for "Go to" navigation)
    let selectionId: String? // Current selection ID (e.g., playlist ID) for back navigation

    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaylistService.self) private var playlistService

    @State private var isTogglingFavorite = false
    @State private var showNewPlaylistDialog = false
    @State private var newPlaylistName = ""
    @State private var isAddingToPlaylist = false
    @State private var showPlaylistAddedSuccess = false

    /// Favorite status from the store (single source of truth)
    private var isFavorited: Bool {
        store.isFavorite(track.trackId)
    }

    init(
        track: TrackRowData,
        showTrackNumber: Bool = false,
        index: Int? = nil,
        currentlyPlayingURI: String?,
        currentIndex: Int? = nil,
        playbackViewModel: PlaybackViewModel,
        doubleTapBehavior: TrackRowDoubleTapBehavior = .playTrack,
        currentSection: NavigationItem = .startpage,
        selectionId: String? = nil,
    ) {
        self.track = track
        self.showTrackNumber = showTrackNumber
        self.index = index
        isCurrentTrack = currentlyPlayingURI == track.uri
        isPlayedTrack = if let index, let currentIndex {
            index < currentIndex
        } else {
            false
        }
        self.playbackViewModel = playbackViewModel
        self.doubleTapBehavior = doubleTapBehavior
        self.currentSection = currentSection
        self.selectionId = selectionId
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number, index, or now playing indicator
            ZStack {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .symbolEffect(.variableColor.iterative, isActive: playbackViewModel.isPlaying)
                } else if showTrackNumber, let trackNumber = track.trackNumber {
                    Text("\(trackNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let index {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // No number shown
                    EmptyView()
                }
            }
            .frame(width: 30, alignment: showTrackNumber ? .trailing : .center)

            // Album art (if available)
            if let albumArtURL = track.albumArtURL, !albumArtURL.isEmpty, let url = URL(string: albumArtURL) {
                AsyncImage(url: url) { phase in
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
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline)
                    .fontWeight(isCurrentTrack ? .semibold : .regular)
                    .foregroundStyle(isCurrentTrack ? .green : .primary)
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

            // Heart button (favorite status from store)
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.caption)
                    .foregroundStyle(isFavorited ? .red : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTogglingFavorite)
            .opacity(isTogglingFavorite ? 0.5 : 1.0)

            // Context menu (3-dot button)
            Menu {
                TrackContextMenu(
                    track: track,
                    currentSection: currentSection,
                    selectionId: selectionId,
                    playbackViewModel: playbackViewModel,
                    showNewPlaylistDialog: $showNewPlaylistDialog,
                    onPlaylistAdded: showSuccessFeedback,
                )
            } label: {
                Image(systemName: showPlaylistAddedSuccess ? "checkmark.circle.fill" : "ellipsis")
                    .font(.caption)
                    .foregroundColor(showPlaylistAddedSuccess ? Color.green : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .animation(.easeInOut(duration: 0.2), value: showPlaylistAddedSuccess)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(showPlaylistAddedSuccess)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isCurrentTrack ? Color.green.opacity(0.1) : Color.clear)
        .opacity(isPlayedTrack ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .contextMenu {
            TrackContextMenu(
                track: track,
                currentSection: currentSection,
                selectionId: selectionId,
                playbackViewModel: playbackViewModel,
                showNewPlaylistDialog: $showNewPlaylistDialog,
                onPlaylistAdded: showSuccessFeedback,
            )
        }
        .onTapGesture(count: 2) {
            handleDoubleTap()
        }
        .alert("playlist.new.title", isPresented: $showNewPlaylistDialog) {
            TextField("playlist.new.placeholder", text: $newPlaylistName)
            Button("action.cancel", role: .cancel) {
                newPlaylistName = ""
            }
            Button("action.create") {
                createAndAddToPlaylist(name: newPlaylistName)
                newPlaylistName = ""
            }
            .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("playlist.new.message")
        }
    }

    private func handleDoubleTap() {
        switch doubleTapBehavior {
        case .playTrack:
            Task {
                let token = await session.validAccessToken()
                await playbackViewModel.play(
                    uriOrUrl: track.uri,
                    accessToken: token,
                )
            }
        }
    }

    /// Toggle favorite using TrackService (optimistic update)
    private func toggleFavorite() {
        Task {
            isTogglingFavorite = true

            do {
                let token = await session.validAccessToken()
                try await trackService.toggleFavorite(
                    trackId: track.trackId,
                    accessToken: token,
                )
            } catch {
                // Error is handled by optimistic rollback in TrackService
                playbackViewModel.errorMessage = "Failed to update favorite: \(error.localizedDescription)"
            }

            isTogglingFavorite = false
        }
    }

    /// Create a new playlist and add the track to it
    private func createAndAddToPlaylist(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        Task {
            isAddingToPlaylist = true
            do {
                let token = await session.validAccessToken()

                // Create the playlist using PlaylistService
                let newPlaylist = try await playlistService.createPlaylist(
                    userId: session.userId ?? "",
                    name: trimmedName,
                    accessToken: token,
                )

                // Add the track to the new playlist
                try await playlistService.addTracksToPlaylist(
                    playlistId: newPlaylist.id,
                    trackIds: [track.trackId],
                    accessToken: token,
                )

                showSuccessFeedback()
            } catch {
                playbackViewModel.errorMessage = "Failed to create playlist: \(error.localizedDescription)"
            }
            isAddingToPlaylist = false
        }
    }

    private func showSuccessFeedback() {
        showPlaylistAddedSuccess = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showPlaylistAddedSuccess = false
        }
    }
}

// MARK: - Conversions from different track types

extension QueueItem {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: uri,
            uri: uri,
            name: trackName,
            artistName: artistName,
            albumArtURL: albumArtURL,
            durationMs: Int(durationMs),
            trackNumber: nil,
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}

extension APITrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: trackNumber,
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}
