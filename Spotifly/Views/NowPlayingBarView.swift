//
//  NowPlayingBarView.swift
//  Spotifly
//
//  Persistent now playing bar at the bottom of the window
//

import SwiftUI

struct NowPlayingBarView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(TrackService.self) private var trackService
    @Environment(PlaylistService.self) private var playlistService
    @Bindable var playbackViewModel: PlaybackViewModel
    @ObservedObject var windowState: WindowState

    @State private var cachedAlbumArtImage: Image?
    @State private var cachedAlbumArtURL: String?
    @State private var showVolumePopover = false
    @State private var isHoveringSeekBar = false
    @State private var showNewPlaylistDialog = false
    @State private var newPlaylistName = ""
    @State private var showPlaylistAddedSuccess = false

    /// Whether something is currently playing or queued
    private var hasPlayback: Bool {
        playbackViewModel.currentTrackUri != nil
    }

    /// Extract track ID from URI (spotify:track:XXXX -> XXXX)
    private var currentTrackId: String? {
        guard let uri = playbackViewModel.currentTrackUri else { return nil }
        return SpotifyAPI.parseTrackURI(uri)
    }

    /// Current track from global store (populated by QueueService)
    private var currentTrack: Track? {
        guard let trackId = currentTrackId else { return nil }
        return store.tracks[trackId]
    }

    /// Current track data for the context menu
    private var currentTrackData: TrackRowData? {
        guard let track = currentTrack,
              let uri = playbackViewModel.currentTrackUri
        else {
            return nil
        }

        return TrackRowData(
            id: track.id,
            uri: uri,
            name: track.name,
            artistName: track.artistName,
            albumArtURL: track.imageURL?.absoluteString,
            durationMs: track.durationMs,
            trackNumber: track.trackNumber,
            albumId: track.albumId,
            artistId: track.artistId,
            externalUrl: track.externalUrl,
        )
    }

    // Fixed dimensions for the now playing bar (in points)
    private let barWidth: CGFloat = 700
    private let barHeight: CGFloat = 60

    var body: some View {
        playerLayout
            .frame(width: windowState.isMiniPlayerMode ? nil : barWidth, height: windowState.isMiniPlayerMode ? nil : barHeight)
            .frame(maxWidth: windowState.isMiniPlayerMode ? .infinity : nil, maxHeight: windowState.isMiniPlayerMode ? .infinity : nil)
            .modifier(NowPlayingBarBackground(isMiniPlayerMode: windowState.isMiniPlayerMode))
            .padding([.leading, .trailing], windowState.isMiniPlayerMode ? 0 : 40)
            .padding([.bottom], windowState.isMiniPlayerMode ? 0 : 20)
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

    // MARK: - Player Layout

    private var playerLayout: some View {
        HStack(spacing: 24) {
            // Left: Playback controls
            playbackControls

            // Center: Track info with seek bar below
            VStack(spacing: 4) {
                // Top row: Cover | Title & Artist | Menu
                HStack(spacing: 10) {
                    albumArt(size: 34)

                    trackInfo
                        .frame(maxWidth: .infinity, alignment: .leading)

                    trackMenu
                }

                // Bottom row: Seek bar spanning full width
                progressBar
            }
            .frame(maxWidth: 350)

            // Right: Other controls
            HStack(spacing: 16) {
                favoriteButton

                queuePosition

                miniPlayerToggle

                volumeControl
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Shared Components

    private func albumArt(size: CGFloat) -> some View {
        Group {
            if let url = currentTrack?.imageURL {
                let urlString = url.absoluteString
                if let cachedImage = cachedAlbumArtImage, cachedAlbumArtURL == urlString {
                    // Use cached image
                    cachedImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    // Load new image
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: size, height: size)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: size, height: size)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .onAppear {
                                    cachedAlbumArtImage = image
                                    cachedAlbumArtURL = urlString
                                }
                        case .failure:
                            placeholderAlbumArt(size: size)
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            } else {
                placeholderAlbumArt(size: size)
            }
        }
    }

    private func placeholderAlbumArt(size: CGFloat) -> some View {
        Image(systemName: "music.note")
            .font(.title3)
            .frame(width: size, height: size)
            .background(Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let track = currentTrack {
                Text(track.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 16) {
            Button {
                playbackViewModel.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!playbackViewModel.hasPrevious)

            Button {
                if playbackViewModel.isPlaying {
                    playbackViewModel.pause()
                } else {
                    playbackViewModel.resume()
                }
            } label: {
                Image(systemName: playbackViewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Button {
                playbackViewModel.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!playbackViewModel.hasNext)
        }
    }

    /// Current playback position (interpolated for smooth display)
    private var currentPositionMs: UInt32 {
        playbackViewModel.interpolatedPositionMs
    }

    /// Current track duration (from store, fallback to playback state)
    private var currentDurationMs: UInt32 {
        if let track = currentTrack {
            return UInt32(track.durationMs)
        }
        return playbackViewModel.trackDurationMs
    }

    private var progressBar: some View {
        // TimelineView updates at display refresh rate for smooth slider
        TimelineView(.animation(minimumInterval: 0.033)) { _ in
            HStack(spacing: 8) {
                // Show timestamp only on hover
                if isHoveringSeekBar {
                    Text(formatTrackTime(milliseconds: Int(currentPositionMs)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Slider(
                    value: Binding(
                        get: { Double(currentPositionMs) },
                        set: { newValue in
                            playbackViewModel.seek(to: UInt32(newValue))
                        },
                    ),
                    in: 0 ... Double(max(currentDurationMs, 1)),
                )
                .controlSize(.mini)
                .tint(.green)

                // Show timestamp only on hover
                if isHoveringSeekBar {
                    Text(formatTrackTime(milliseconds: Int(currentDurationMs)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(height: 12) // Fixed height prevents layout shift on hover
            .animation(.easeInOut(duration: 0.15), value: isHoveringSeekBar)
            .onHover { hovering in
                isHoveringSeekBar = hovering
            }
        }
    }

    private var queuePosition: some View {
        Button {
            exitMiniPlayerIfNeeded()
            navigationCoordinator.navigateToQueue()
        } label: {
            Text("\(store.currentIndex + 1)/\(store.queueLength)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    /// Whether the current track is favorited (from global store)
    private var isCurrentTrackFavorited: Bool {
        guard let trackId = currentTrackId else { return false }
        return store.isFavorite(trackId)
    }

    private var favoriteButton: some View {
        Button {
            Task {
                guard let trackId = currentTrackId else { return }
                let token = await session.validAccessToken()
                try? await trackService.toggleFavorite(trackId: trackId, accessToken: token)
            }
        } label: {
            Image(systemName: isCurrentTrackFavorited ? "heart.fill" : "heart")
                .font(.body)
                .foregroundStyle(isCurrentTrackFavorited ? .red : .secondary)
        }
        .buttonStyle(.plain)
    }

    /// Unified volume (0-100 scale)
    private var currentVolume: Double {
        playbackViewModel.volume * 100
    }

    private func setVolume(_ volume: Double) {
        playbackViewModel.volume = volume / 100
    }

    private var volumeControl: some View {
        Button {
            showVolumePopover.toggle()
        } label: {
            Image(systemName: currentVolume == 0 ? "speaker.fill" : currentVolume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showVolumePopover, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { currentVolume },
                        set: { setVolume($0) },
                    ),
                    in: 0 ... 100,
                )
                .tint(.green)
                .frame(width: 120)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private var miniPlayerToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                windowState.toggleMiniPlayerMode()
            }
        } label: {
            Image(systemName: windowState.isMiniPlayerMode ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(windowState.isMiniPlayerMode ? "mini_player.restore" : "mini_player.enter")
    }

    @ViewBuilder
    private var trackMenu: some View {
        if let track = currentTrackData {
            Menu {
                TrackContextMenu(
                    track: track,
                    currentSection: .queue,
                    selectionId: nil,
                    playbackViewModel: playbackViewModel,
                    showNewPlaylistDialog: $showNewPlaylistDialog,
                    onPlaylistAdded: showSuccessFeedback,
                    onNavigate: exitMiniPlayerIfNeeded,
                )
            } label: {
                Image(systemName: showPlaylistAddedSuccess ? "checkmark.circle.fill" : "ellipsis")
                    .font(.body)
                    .foregroundColor(showPlaylistAddedSuccess ? .green : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .animation(.easeInOut(duration: 0.2), value: showPlaylistAddedSuccess)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(showPlaylistAddedSuccess)
        }
    }

    private func exitMiniPlayerIfNeeded() {
        if windowState.isMiniPlayerMode {
            windowState.toggleMiniPlayerMode()
        }
    }

    private func showSuccessFeedback() {
        showPlaylistAddedSuccess = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showPlaylistAddedSuccess = false
        }
    }

    private func createAndAddToPlaylist(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let track = currentTrackData else { return }

        Task {
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
        }
    }
}

// MARK: - Glass Effect Background

/// Applies either a solid background (mini player) or liquid glass effect (expanded mode)
private struct NowPlayingBarBackground: ViewModifier {
    let isMiniPlayerMode: Bool

    func body(content: Content) -> some View {
        if isMiniPlayerMode {
            content
                .background(Color(NSColor.windowBackgroundColor))
        } else {
            content
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
    }
}
