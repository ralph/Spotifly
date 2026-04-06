//
//  TrackRow.swift
//  Spotifly
//
//  Reusable track row component for displaying tracks across different views
//

import SwiftUI

/// Reusable track row view
struct TrackRow: View {
    let track: Track
    let showTrackNumber: Bool // Show track number instead of index
    let index: Int? // Optional index for queue
    let isCurrentTrack: Bool
    let isPlayedTrack: Bool // For queue - tracks that have already played
    let provider: TrackProvider? // Optional provider (queue, context, autoplay, unavailable)
    @Bindable var playbackViewModel: PlaybackViewModel
    let currentSection: NavigationItem // Current sidebar section (for "Go to" navigation)
    let selectionId: String? // Current selection ID (e.g., playlist ID) for back navigation
    let onDoubleTap: (@MainActor () async -> Void)? // Playback action on double-tap

    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaylistService.self) private var playlistService
    @Environment(\.displayScale) private var displayScale

    @State private var isTogglingFavorite = false
    @State private var showNewPlaylistDialog = false
    @State private var newPlaylistName = ""
    @State private var isAddingToPlaylist = false
    @State private var showPlaylistAddedSuccess = false

    /// Favorite status from the store (single source of truth)
    private var isFavorited: Bool {
        store.isFavorite(track.id)
    }

    /// Provider symbol for display (Q=queue, C=context, A=autoplay, nil for unavailable)
    private var providerSymbol: String? {
        switch provider {
        case .queue: "Q"
        case .context: "C"
        case .autoplay: "A"
        case .unavailable, .none: nil
        }
    }

    /// Whether the row should be disabled (unavailable tracks)
    private var isUnavailable: Bool {
        provider == .unavailable
    }

    init(
        track: Track,
        showTrackNumber: Bool = false,
        index: Int? = nil,
        currentlyPlayingURI: String?,
        currentIndex: Int? = nil,
        provider: TrackProvider? = nil,
        playbackViewModel: PlaybackViewModel,
        currentSection: NavigationItem = .startpage,
        selectionId: String? = nil,
        onDoubleTap: (@MainActor () async -> Void)? = nil,
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
        self.provider = provider
        self.playbackViewModel = playbackViewModel
        self.currentSection = currentSection
        self.selectionId = selectionId
        self.onDoubleTap = onDoubleTap
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number, index, or now playing indicator
            ZStack {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
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
            if let url = track.images.url(for: 40, scale: displayScale) {
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

            // Provider indicator (Q=queue, C=context, A=autoplay)
            if let symbol = providerSymbol {
                Text(symbol)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
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
        .opacity(isPlayedTrack || isUnavailable ? 0.5 : 1.0)
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
            guard let onDoubleTap else { return }
            Task { await onDoubleTap() }
        }
        .task(id: track.id) {
            await resolveFavoriteStatusIfNeeded()
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

    /// Toggle favorite using TrackService (optimistic update)
    private func toggleFavorite() {
        Task {
            isTogglingFavorite = true

            do {
                let token = await session.validAccessToken()
                try await trackService.toggleFavorite(
                    trackId: track.id,
                    accessToken: token,
                )
            } catch {
                // Error is handled by optimistic rollback in TrackService
                playbackViewModel.errorMessage = "Failed to update favorite: \(error.localizedDescription)"
            }

            isTogglingFavorite = false
        }
    }

    private func resolveFavoriteStatusIfNeeded() async {
        guard !store.hasResolvedFavoriteStatus(for: track.id) else { return }

        let token = await session.validAccessToken()
        await trackService.ensureFavoriteStatuses(trackIds: [track.id], accessToken: token)
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
                    name: trimmedName,
                    accessToken: token,
                )

                // Add the track to the new playlist
                try await playlistService.addTracksToPlaylist(
                    playlistId: newPlaylist.id,
                    trackIds: [track.id],
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

// MARK: - QueueItem to Track Conversion

extension QueueItem {
    /// Convert QueueItem to Track for use with TrackRow and store operations.
    /// Wraps the single FFI image URL as a ~300px variant; full metadata
    /// arrives later via QueueService and replaces this in the store.
    func toTrack() -> Track {
        let images = imageURL.map { ImageSet(variants: [ImageVariant(url: $0, size: 300)]) } ?? .empty
        return Track(
            id: SpotifyAPI.parseTrackURI(uri) ?? id,
            name: name,
            uri: uri,
            durationMs: Int(durationMs),
            trackNumber: nil,
            externalUrl: externalUrl,
            albumId: albumId,
            artistId: artistId,
            artistName: artistName,
            albumName: nil,
            images: images,
        )
    }
}
