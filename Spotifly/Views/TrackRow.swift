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
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Extracts the track ID for API calls (handles both plain IDs and URIs)
    var trackId: String {
        // If id looks like a URI (spotify:track:xxx), extract just the ID
        if id.hasPrefix("spotify:track:") {
            return String(id.dropFirst("spotify:track:".count))
        }
        return id
    }
}

/// Double-tap behavior for TrackRow
enum TrackRowDoubleTapBehavior {
    case playTrack // Play just this track
    case jumpToQueueIndex // Jump to this index in the queue (for QueueListView)
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

            // Context menu
            Menu {
                Button {
                    playNext()
                } label: {
                    Label("track.menu.play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    addToQueue()
                } label: {
                    Label("track.menu.add_to_queue", systemImage: "text.append")
                }

                Button {
                    startSongRadio()
                } label: {
                    Label("track.menu.start_radio", systemImage: "antenna.radiowaves.left.and.right")
                }

                Divider()

                // Playlist Management Section
                Menu {
                    Button {
                        showNewPlaylistDialog = true
                    } label: {
                        Label("track.menu.add_to_new_playlist", systemImage: "plus")
                    }

                    // Show playlists from store
                    let ownedPlaylists = store.userPlaylists.filter { $0.ownerId == session.userId }
                    if !ownedPlaylists.isEmpty {
                        Divider()

                        ForEach(ownedPlaylists) { playlist in
                            Button(playlist.name) {
                                addToPlaylist(playlistId: playlist.id)
                            }
                        }
                    }
                } label: {
                    Label("track.menu.add_to_playlist", systemImage: "music.note.list")
                }

                Divider()

                Button {
                    if let artistId = track.artistId {
                        Task {
                            let token = await session.validAccessToken()
                            navigationCoordinator.navigateToArtist(
                                artistId: artistId,
                                accessToken: token,
                            )
                        }
                    }
                } label: {
                    Label("track.menu.go_to_artist", systemImage: "person.circle")
                }
                .disabled(track.artistId == nil)

                Button {
                    if let albumId = track.albumId {
                        Task {
                            let token = await session.validAccessToken()
                            navigationCoordinator.navigateToAlbum(
                                albumId: albumId,
                                accessToken: token,
                            )
                        }
                    }
                } label: {
                    Label("track.menu.go_to_album", systemImage: "square.stack")
                }
                .disabled(track.albumId == nil)

                Divider()

                Button {
                    copyToClipboard()
                } label: {
                    Label("action.share", systemImage: "square.and.arrow.up")
                }
                .disabled(track.externalUrl == nil)
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
        .task {
            // Load user ID and playlists if not already loaded
            await session.loadUserIdIfNeeded()
            // Load playlists via service if store is empty
            if store.userPlaylists.isEmpty, !store.playlistsPagination.isLoading {
                let token = await session.validAccessToken()
                try? await playlistService.loadUserPlaylists(accessToken: token)
            }
        }
    }

    private func copyToClipboard() {
        guard let externalUrl = track.externalUrl else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(externalUrl, forType: .string)
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
        case .jumpToQueueIndex:
            guard let index else { return }
            do {
                try SpotifyPlayer.jumpToIndex(index)
                playbackViewModel.updateQueueState()
            } catch {
                playbackViewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func playNext() {
        Task {
            let token = await session.validAccessToken()
            await playbackViewModel.playNext(
                trackUri: track.uri,
                accessToken: token,
            )
        }
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

                // Ensure player is initialized (needed for radio API)
                await playbackViewModel.initializeIfNeeded(accessToken: token)

                // Use librespot's internal radio API
                let radioTrackUris = try SpotifyPlayer.getRadioTracks(trackUri: track.uri)

                if !radioTrackUris.isEmpty {
                    // Filter out the base track if it's already in the radio results
                    let filteredRadioUris = radioTrackUris.filter { $0 != track.uri }

                    // Play the current track followed by radio tracks
                    var trackUris = [track.uri]
                    trackUris.append(contentsOf: filteredRadioUris)

                    await playbackViewModel.playTracks(
                        trackUris,
                        accessToken: token,
                    )

                    // Navigate to queue to show radio tracks
                    navigationCoordinator.navigateToQueue()
                } else {
                    playbackViewModel.errorMessage = "No radio tracks found"
                }
            } catch {
                playbackViewModel.errorMessage = "Failed to start radio: \(error.localizedDescription)"
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

    /// Add track to playlist using PlaylistService
    private func addToPlaylist(playlistId: String) {
        Task {
            isAddingToPlaylist = true
            do {
                let token = await session.validAccessToken()
                try await playlistService.addTracksToPlaylist(
                    playlistId: playlistId,
                    trackIds: [track.trackId],
                    accessToken: token,
                )
                showSuccessFeedback()
            } catch {
                playbackViewModel.errorMessage = "Failed to add to playlist: \(error.localizedDescription)"
            }
            isAddingToPlaylist = false
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

extension AlbumTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: nil, // Album tracks don't have individual art
            durationMs: durationMs,
            trackNumber: trackNumber,
            albumId: nil, // Not needed - already viewing the album
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}

extension PlaylistTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: nil,
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}

extension SearchTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: nil,
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}

extension SavedTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: nil,
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}
