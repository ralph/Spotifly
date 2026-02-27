//
//  NowPlayingBarView.swift
//  Spotifly
//
//  Persistent now playing bar at the bottom of the window
//

import AppKit
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
    @State private var showAlbumArtMenu = false
    @State private var showNewPlaylistDialog = false
    @State private var newPlaylistName = ""
    @State private var showPlaylistAddedSuccess = false
    @AppStorage("perf.nowPlaying.hideBar") private var perfHideBar = false
    #if DEBUG
        @AppStorage("perf.nowPlaying.aggressiveIsolation") private var perfAggressiveIsolation = true
        @AppStorage("perf.nowPlaying.flatBackground") private var perfFlatBackground = true
    #else
        @AppStorage("perf.nowPlaying.aggressiveIsolation") private var perfAggressiveIsolation = false
        @AppStorage("perf.nowPlaying.flatBackground") private var perfFlatBackground = false
    #endif
    @AppStorage("perf.nowPlaying.disableSeekBar") private var perfDisableSeekBar = false
    @AppStorage("perf.nowPlaying.disableAlbumArt") private var perfDisableAlbumArt = false
    @AppStorage("perf.nowPlaying.disableTrackMenu") private var perfDisableTrackMenu = false
    @AppStorage("perf.nowPlaying.disableRightControls") private var perfDisableRightControls = false
    @AppStorage("perf.nowPlaying.disableVolumePopover") private var perfDisableVolumePopover = false

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

    // Fixed dimensions for the now playing bar (in points)
    private let barWidth: CGFloat = 700
    private let barHeight: CGFloat = 60
    private let expandedHorizontalPadding: CGFloat = 40
    private let expandedBottomPadding: CGFloat = 20

    private var useAggressiveIsolation: Bool {
        perfAggressiveIsolation
    }

    private var forceFlatBackground: Bool {
        useAggressiveIsolation || perfFlatBackground
    }

    private var showSeekBarControl: Bool {
        !perfDisableSeekBar
    }

    private var showAlbumArtControl: Bool {
        !perfDisableAlbumArt
    }

    private var showTrackMenuControl: Bool {
        !perfDisableTrackMenu
    }

    private var showRightControls: Bool {
        !perfDisableRightControls
    }

    private var showVolumePopoverControl: Bool {
        !perfDisableVolumePopover
    }

    private var minimumExpandedBarAreaWidth: CGFloat {
        guard !windowState.isMiniPlayerMode, !useAggressiveIsolation else { return 0 }
        return barWidth + (expandedHorizontalPadding * 2)
    }

    @ViewBuilder
    var body: some View {
        if perfHideBar {
            EmptyView()
        } else {
            playerLayout
                // Use maxWidth instead of fixed width so the bar can shrink on narrow windows.
                .frame(maxWidth: windowState.isMiniPlayerMode ? .infinity : barWidth)
                .frame(height: windowState.isMiniPlayerMode ? nil : barHeight)
                .frame(maxWidth: .infinity, maxHeight: windowState.isMiniPlayerMode ? .infinity : nil)
                .modifier(
                    NowPlayingBarBackground(
                        isMiniPlayerMode: windowState.isMiniPlayerMode,
                        forceFlatBackground: forceFlatBackground,
                    ),
                )
                .padding([.leading, .trailing], windowState.isMiniPlayerMode ? 0 : expandedHorizontalPadding)
                .padding([.bottom], windowState.isMiniPlayerMode ? 0 : expandedBottomPadding)
                // Keep enough width in expanded mode so the full bar remains visible.
                .frame(minWidth: minimumExpandedBarAreaWidth)
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
    }

    // MARK: - Player Layout

    @ViewBuilder
    private var playerLayout: some View {
        if useAggressiveIsolation {
            isolatedPlayerLayout
        } else {
            fullPlayerLayout
        }
    }

    private var isolatedPlayerLayout: some View {
        HStack(spacing: 12) {
            minimalPlaybackControls

            if let track = currentTrack {
                Text(track.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            } else {
                Text("No track")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var fullPlayerLayout: some View {
        HStack(spacing: 24) {
            // Left: Playback controls
            playbackControls

            // Center: Track info with optional seek bar below
            VStack(spacing: 4) {
                // Top row: Cover | Title & Artist | Menu
                HStack(spacing: 10) {
                    if showAlbumArtControl {
                        Button {
                            showAlbumArtMenu.toggle()
                        } label: {
                            albumArt(size: 34)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .popover(isPresented: $showAlbumArtMenu, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                if let artistId = currentTrack?.artistId {
                                    Button {
                                        showAlbumArtMenu = false
                                        navigationCoordinator.navigateToArtist(artistId: artistId)
                                    } label: {
                                        Label("track.menu.go_to_artist", systemImage: "person.circle")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }

                                if let albumId = currentTrack?.albumId {
                                    Button {
                                        showAlbumArtMenu = false
                                        navigationCoordinator.navigateToAlbum(albumId: albumId)
                                    } label: {
                                        Label("track.menu.go_to_album", systemImage: "square.stack")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }

                                Button {
                                    showAlbumArtMenu = false
                                    navigationCoordinator.navigateToQueue()
                                } label: {
                                    Label("queue.title", systemImage: "list.number")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    trackInfo
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if showTrackMenuControl {
                        trackMenu
                    }
                }

                if showSeekBarControl {
                    // Bottom row: Seek bar spanning full width
                    NowPlayingProgressBarView(playbackViewModel: playbackViewModel)
                }
            }
            .frame(maxWidth: 350)

            if showRightControls {
                // Right: Other controls
                HStack(spacing: 16) {
                    favoriteButton
                    queuePosition
                    miniPlayerToggle
                    volumeControl
                }
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
                Image(systemName: playbackViewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
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

    private var minimalPlaybackControls: some View {
        Button {
            if playbackViewModel.isPlaying {
                playbackViewModel.pause()
            } else {
                playbackViewModel.resume()
            }
        } label: {
            Image(systemName: playbackViewModel.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
        }
        .buttonStyle(.plain)
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

    private var volumeIconName: String {
        if currentVolume == 0 {
            return "speaker.fill"
        }
        return currentVolume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }

    private func setVolume(_ volume: Double) {
        playbackViewModel.volume = volume / 100
    }

    @ViewBuilder
    private var volumeControl: some View {
        if showVolumePopoverControl {
            Button {
                showVolumePopover.toggle()
            } label: {
                Image(systemName: volumeIconName)
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
        } else {
            Image(systemName: volumeIconName)
                .font(.body)
                .foregroundStyle(.secondary)
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
        .help(windowState.isMiniPlayerMode ? String(localized: "mini_player.restore") : String(localized: "mini_player.enter"))
    }

    @ViewBuilder
    private var trackMenu: some View {
        if let track = currentTrack {
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
        guard !trimmedName.isEmpty, let track = currentTrack else { return }

        Task {
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
        }
    }
}

// MARK: - Progress Bar

private struct NowPlayingProgressBarView: View {
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var isHoveringSeekBar = false

    /// Current playback position updated by the playback view model.
    private var currentPositionMs: UInt32 {
        playbackViewModel.currentPositionMs
    }

    /// Current track duration from playback state.
    private var currentDurationMs: UInt32 {
        playbackViewModel.trackDurationMs
    }

    var body: some View {
        progressBar
    }

    @ViewBuilder
    private var progressBar: some View {
        // Only run timeline-based interpolation while actively hovering the seek bar.
        // In steady state we render from model-updated position values to reduce layout churn.
        if playbackViewModel.isPlaying, isHoveringSeekBar {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                progressBarContent(positionMs: playbackViewModel.interpolatedPositionMs)
            }
        } else {
            progressBarContent(positionMs: currentPositionMs)
        }
    }

    private func progressBarContent(positionMs: UInt32) -> some View {
        HStack(spacing: 8) {
            Text(formatTrackTime(milliseconds: Int(positionMs)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
                .opacity(isHoveringSeekBar ? 1 : 0)
                .allowsHitTesting(false)

            Group {
                if isHoveringSeekBar {
                    LightweightSeekBar(
                        positionMs: positionMs,
                        durationMs: currentDurationMs,
                        onSeek: { position in
                            playbackViewModel.seek(to: position)
                        },
                    )
                } else {
                    PassiveProgressBar(
                        positionMs: positionMs,
                        durationMs: currentDurationMs,
                    )
                }
            }

            Text(formatTrackTime(milliseconds: Int(currentDurationMs)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 56, alignment: .leading)
                .opacity(isHoveringSeekBar ? 1 : 0)
                .allowsHitTesting(false)
        }
        .frame(height: 12)
        .animation(.easeInOut(duration: 0.15), value: isHoveringSeekBar)
        .onHover { hovering in
            isHoveringSeekBar = hovering
        }
    }
}

// MARK: - Lightweight Seek Bar

private struct PassiveProgressBar: View {
    let positionMs: UInt32
    let durationMs: UInt32

    private var progress: CGFloat {
        guard durationMs > 0 else { return 0 }
        let value = Double(positionMs) / Double(durationMs)
        return CGFloat(max(0, min(1, value)))
    }

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.16))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.green)
                    .scaleEffect(x: progress, y: 1, anchor: .leading)
            }
            .frame(height: 4)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

/// Pure SwiftUI seek bar to avoid NSSlider's expensive AppKit layout updates.
private struct LightweightSeekBar: View {
    let positionMs: UInt32
    let durationMs: UInt32
    let onSeek: (UInt32) -> Void

    @State private var isDragging = false
    @State private var dragPositionMs: UInt32 = 0

    private var displayedPositionMs: UInt32 {
        isDragging ? dragPositionMs : positionMs
    }

    var body: some View {
        GeometryReader { geometry in
            let progress = normalizedProgress(for: displayedPositionMs)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.green)
                    .frame(width: max(4, geometry.size.width * progress), height: 4)

                Circle()
                    .fill(Color.green)
                    .frame(width: isDragging ? 10 : 8, height: isDragging ? 10 : 8)
                    .offset(x: knobOffsetX(in: geometry.size.width, progress: progress))
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let position = seekPosition(from: value.location.x, width: geometry.size.width)
                        isDragging = true
                        dragPositionMs = position
                        onSeek(position)
                    }
                    .onEnded { value in
                        let position = seekPosition(from: value.location.x, width: geometry.size.width)
                        dragPositionMs = position
                        onSeek(position)
                        isDragging = false
                    },
            )
        }
    }

    private func normalizedProgress(for position: UInt32) -> CGFloat {
        guard durationMs > 0 else { return 0 }
        let progress = Double(position) / Double(durationMs)
        return CGFloat(max(0, min(1, progress)))
    }

    private func seekPosition(from x: CGFloat, width: CGFloat) -> UInt32 {
        guard durationMs > 0 else { return 0 }
        let clampedWidth = max(width, 1)
        let clampedX = max(0, min(x, clampedWidth))
        let ratio = clampedX / clampedWidth
        return UInt32(Double(durationMs) * ratio)
    }

    private func knobOffsetX(in width: CGFloat, progress: CGFloat) -> CGFloat {
        let knobRadius = isDragging ? CGFloat(5) : CGFloat(4)
        let knobCenterX = min(max(width * progress, knobRadius), max(knobRadius, width - knobRadius))
        return knobCenterX - knobRadius
    }
}

// MARK: - Glass Effect Background

/// Applies either a solid background (mini player) or liquid glass effect (expanded mode)
private struct NowPlayingBarBackground: ViewModifier {
    let isMiniPlayerMode: Bool
    let forceFlatBackground: Bool

    func body(content: Content) -> some View {
        if isMiniPlayerMode || forceFlatBackground {
            content
                .background(Color(NSColor.windowBackgroundColor))
        } else {
            content
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
    }
}
