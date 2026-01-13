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
    @Environment(ConnectService.self) private var connectService
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
        playbackViewModel.queueLength > 0 || store.isSpotifyConnectActive
    }

    /// Current track data for the context menu
    private var currentTrackData: TrackRowData? {
        guard let trackName = store.isSpotifyConnectActive ? store.currentTrackName : playbackViewModel.currentTrackName,
              let trackUri = playbackViewModel.currentlyPlayingURI
        else {
            return nil
        }

        let artistName = (store.isSpotifyConnectActive ? store.currentArtistName : playbackViewModel.currentArtistName) ?? ""

        // Try to get the full queue item for extra metadata (albumId, artistId, externalUrl)
        let queueItem: QueueItem? = {
            guard playbackViewModel.queueLength > 0 else { return nil }
            guard let items = try? SpotifyPlayer.getAllQueueItems(),
                  playbackViewModel.currentIndex < items.count
            else { return nil }
            return items[playbackViewModel.currentIndex]
        }()

        return TrackRowData(
            id: playbackViewModel.currentTrackId ?? trackUri,
            uri: trackUri,
            name: trackName,
            artistName: artistName,
            albumArtURL: playbackViewModel.currentAlbumArtURL,
            durationMs: Int(currentDurationMs),
            trackNumber: nil,
            albumId: queueItem?.albumId,
            artistId: queueItem?.artistId,
            externalUrl: queueItem?.externalUrl,
        )
    }

    // Helper function for time formatting
    private func formatTime(_ milliseconds: UInt32) -> String {
        let totalSeconds = Int(milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Fixed dimensions for the now playing bar (in points)
    private let barWidth: CGFloat = 700
    private let barHeight: CGFloat = 60

    var body: some View {
        playerLayout
            .frame(width: windowState.isMiniPlayerMode ? nil : barWidth, height: windowState.isMiniPlayerMode ? nil : barHeight)
            .frame(maxWidth: windowState.isMiniPlayerMode ? .infinity : nil, maxHeight: windowState.isMiniPlayerMode ? .infinity : nil)
            .modifier(NowPlayingBarBackground(isMiniPlayerMode: windowState.isMiniPlayerMode))
            .padding(windowState.isMiniPlayerMode ? 0 : 10)
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
            if let cachedImage = cachedAlbumArtImage,
               cachedAlbumArtURL == playbackViewModel.currentAlbumArtURL
            {
                // Use cached image
                cachedImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let artURL = playbackViewModel.currentAlbumArtURL,
                      !artURL.isEmpty,
                      let url = URL(string: artURL)
            {
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
                                cachedAlbumArtURL = artURL
                            }
                    case .failure:
                        placeholderAlbumArt(size: size)
                    @unknown default:
                        EmptyView()
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
            if let trackName = store.isSpotifyConnectActive ? store.currentTrackName : playbackViewModel.currentTrackName {
                Text(trackName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            if let artistName = store.isSpotifyConnectActive ? store.currentArtistName : playbackViewModel.currentArtistName {
                Text(artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Show device indicator when Connect active - clickable to transfer back
            if store.isSpotifyConnectActive, let deviceName = store.spotifyConnectDeviceName {
                Button {
                    transferToLocalPlayback()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hifispeaker.fill")
                            .font(.caption2)
                        Text(deviceName)
                            .font(.caption2)
                        Image(systemName: "arrow.right.circle")
                            .font(.caption2)
                    }
                    .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("connect.transfer_to_computer")
            }
        }
    }

    private func transferToLocalPlayback() {
        connectService.transferToLocal()
    }

    private var playbackControls: some View {
        HStack(spacing: 16) {
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.previous(accessToken: token)
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!store.isSpotifyConnectActive && !playbackViewModel.hasPrevious)

            Button {
                Task {
                    let token = await session.validAccessToken()
                    let isPlaying = store.isSpotifyConnectActive ? store.isPlaying : playbackViewModel.isPlaying
                    if isPlaying {
                        await playbackViewModel.pause(accessToken: token)
                    } else {
                        await playbackViewModel.resume(accessToken: token)
                    }
                }
            } label: {
                let isPlaying = store.isSpotifyConnectActive ? store.isPlaying : playbackViewModel.isPlaying
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.next(accessToken: token)
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!store.isSpotifyConnectActive && !playbackViewModel.hasNext)
        }
    }

    /// Current playback position (interpolated for smooth display)
    private var currentPositionMs: UInt32 {
        if store.isSpotifyConnectActive {
            store.interpolatedPositionMs
        } else {
            playbackViewModel.interpolatedPositionMs
        }
    }

    /// Current track duration
    private var currentDurationMs: UInt32 {
        if store.isSpotifyConnectActive {
            store.trackDurationMs
        } else {
            playbackViewModel.trackDurationMs
        }
    }

    private var progressBar: some View {
        // TimelineView updates at display refresh rate for smooth slider
        TimelineView(.animation(minimumInterval: 0.033)) { _ in
            HStack(spacing: 8) {
                // Show timestamp only on hover
                if isHoveringSeekBar {
                    Text(formatTime(currentPositionMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Slider(
                    value: Binding(
                        get: { Double(currentPositionMs) },
                        set: { newValue in
                            if store.isSpotifyConnectActive {
                                Task {
                                    let token = await session.validAccessToken()
                                    await connectService.seek(to: Int(newValue), accessToken: token)
                                }
                            } else {
                                playbackViewModel.seekLocal(to: UInt32(newValue))
                            }
                        },
                    ),
                    in: 0 ... Double(max(currentDurationMs, 1)),
                )
                .controlSize(.mini)
                .tint(.green)

                // Show timestamp only on hover
                if isHoveringSeekBar {
                    Text(formatTime(currentDurationMs))
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
            Text("\(playbackViewModel.currentIndex + 1)/\(playbackViewModel.queueLength)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    /// Current track ID for favorite operations (extracted from URI if needed)
    private var currentTrackIdForFavorite: String? {
        guard let trackId = playbackViewModel.currentTrackId else { return nil }
        // Handle URI format: spotify:track:TRACK_ID
        if trackId.hasPrefix("spotify:track:") {
            return String(trackId.dropFirst("spotify:track:".count))
        }
        return trackId
    }

    /// Whether the current track is favorited (from global store)
    private var isCurrentTrackFavorited: Bool {
        guard let trackId = currentTrackIdForFavorite else { return false }
        return store.isFavorite(trackId)
    }

    private var favoriteButton: some View {
        Button {
            Task {
                guard let trackId = currentTrackIdForFavorite else { return }
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

    /// Unified volume (0-100 scale, like Spotify API)
    private var currentVolume: Double {
        let vol = if store.isSpotifyConnectActive {
            store.spotifyConnectVolume
        } else {
            playbackViewModel.volume * 100
        }
        #if DEBUG
            // Uncomment to debug volume issues
            // print("[NowPlayingBar] currentVolume: \(vol), isConnect=\(store.isSpotifyConnectActive), connectVol=\(store.spotifyConnectVolume), localVol=\(playbackViewModel.volume)")
        #endif
        return vol
    }

    private func setVolume(_ volume: Double) {
        if store.isSpotifyConnectActive {
            Task {
                let token = await session.validAccessToken()
                connectService.setVolume(volume, accessToken: token)
            }
        } else {
            playbackViewModel.volume = volume / 100
        }
    }

    private var volumeControl: some View {
        Button {
            showVolumePopover.toggle()
        } label: {
            Image(systemName: currentVolume == 0 ? "speaker.fill" : currentVolume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.body)
                .foregroundStyle(store.isSpotifyConnectActive ? .green : .secondary)
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
