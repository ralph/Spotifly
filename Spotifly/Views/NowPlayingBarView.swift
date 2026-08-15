//
//  NowPlayingBarView.swift
//  Spotifly
//
//  Persistent now playing bar at the bottom of the window
//

import AppKit
import SwiftUI

struct NowPlayingBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(TrackService.self) private var trackService
    @Environment(\.displayScale) private var displayScale
    let playbackViewModel: PlaybackViewModel
    let windowState: WindowState

    @State private var cachedAlbumArtImage: Image?
    @State private var cachedAlbumArtURL: String?
    @State private var showVolumePopover = false
    @State private var showAlbumArtMenu = false
    @State private var isHoveringSeekBar = false
    @State private var showNewPlaylistDialog = false
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
            .newPlaylistPrompt(
                isPresented: $showNewPlaylistDialog,
                trackId: currentTrack?.id,
                playbackViewModel: playbackViewModel,
                onAdded: showSuccessFeedback,
            )
            .task(id: currentTrackId) {
                await resolveCurrentTrackMetadataIfNeeded()
            }
            .task(id: currentTrackId) {
                await resolveCurrentTrackFavoriteStatusIfNeeded()
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
                                albumArtMenuItem("track.menu.go_to_artist", systemImage: "person.circle") {
                                    navigationCoordinator.navigateToArtistSection(artistId: artistId)
                                }
                            }

                            if let albumId = currentTrack?.albumId {
                                albumArtMenuItem("track.menu.go_to_album", systemImage: "square.stack") {
                                    navigationCoordinator.navigateToAlbumSection(albumId: albumId)
                                }
                            }

                            albumArtMenuItem("queue.title", systemImage: "list.number") {
                                navigationCoordinator.navigateToQueue()
                            }
                        }
                        .padding(.vertical, 4)
                    }

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

    /// One row of the cover-art popover. Every row dismisses the popover before it
    /// navigates, so that is here rather than repeated in each action.
    private func albumArtMenuItem(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button {
            showAlbumArtMenu = false
            action()
        } label: {
            Label(titleKey, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func albumArt(size: CGFloat) -> some View {
        if let url = currentTrack?.images.url(for: size, scale: displayScale) {
            let urlString = url.absoluteString
            if let cachedImage = cachedAlbumArtImage, cachedAlbumArtURL == urlString {
                // Use cached image
                cachedImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 4))
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
                            .clipShape(.rect(cornerRadius: 4))
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

    private func placeholderAlbumArt(size: CGFloat) -> some View {
        Image(systemName: "music.note")
            .font(.title3)
            .frame(width: size, height: size)
            .background(Color.gray.opacity(0.2))
            .clipShape(.rect(cornerRadius: 4))
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let track = currentTrack {
                Text(track.name)
                    .font(.subheadline.weight(.medium))
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
            shuffleButton

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

    private var shuffleButton: some View {
        Button {
            playbackViewModel.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.caption)
                .foregroundStyle(playbackViewModel.isShuffleEnabled ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!hasPlayback)
        .help(playbackViewModel.isShuffleEnabled ? "Disable shuffle" : "Enable shuffle")
    }

    /// Current playback position (interpolated for smooth display)
    private var currentPositionMs: UInt32 {
        playbackViewModel.interpolatedPositionMs
    }

    /// Current track duration (from playback state, fallback to store metadata)
    private var currentDurationMs: UInt32 {
        if playbackViewModel.trackDurationMs > 0 {
            return playbackViewModel.trackDurationMs
        }
        return currentTrack.map { UInt32($0.durationMs) } ?? 0
    }

    private var progressBar: some View {
        // Lower frame rate when not hovering: 10 FPS on hover, 1 FPS otherwise
        TimelineView(.animation(minimumInterval: isHoveringSeekBar ? 0.1 : 1.0)) { _ in
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

    /// Where the playing track sits in the queue, as `n/total`.
    ///
    /// Shown only while there is a track to be the `n`. `currentIndex` is
    /// `previousTracks.count`, which lands one past the end whenever the queue holds history
    /// but nothing current — a state a queue reaches simply by playing out — and the label
    /// then read `9/8`. The index is not wrong; the sentence is, because "track n of m" needs
    /// an n. The slot keeps its width either way so the controls beside it do not shift.
    private var queuePosition: some View {
        Button {
            exitMiniPlayerIfNeeded()
            navigationCoordinator.navigateToQueue()
        } label: {
            Group {
                if store.queue.currentTrack != nil {
                    Text("\(store.currentIndex + 1)/\(store.queueLength)")
                } else {
                    // The counter is the button's only label, so dropping it outright would
                    // leave an invisible control that VoiceOver announces unnamed. The glyph
                    // keeps the way into the queue both visible and reachable.
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .help("queue.open")
        .accessibilityLabel("queue.open")
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
                do {
                    try await trackService.toggleFavorite(trackId: trackId)
                } catch {
                    playbackViewModel.errorMessage = "Failed to update favorite: \(error.localizedDescription)"
                }
            }
        } label: {
            Image(systemName: isCurrentTrackFavorited ? "heart.fill" : "heart")
                .font(.body)
                .foregroundStyle(isCurrentTrackFavorited ? .red : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func resolveCurrentTrackMetadataIfNeeded() async {
        guard let trackId = currentTrackId else { return }

        do {
            try await trackService.ensureTracksLoaded(trackIds: [trackId])
            // The task may have outlived this ID. The update is still safe because it
            // resolves PlaybackViewModel's current logical URI rather than `trackId`.
            playbackViewModel.updateNowPlayingInfo()
        } catch {
            debugLog("NowPlayingBarView", "Failed to load metadata for \(trackId): \(error)")
        }
    }

    /// Resolves the heart for whatever is playing.
    ///
    /// `ensureFavoriteStatuses`, not `refreshFavoriteStatuses`: this runs from `.task(id:)`,
    /// which restarts every time the view *appears*, not only when the track changes — and this
    /// bar re-appears often, since it is an overlay on a region that swaps between two- and
    /// three-column layouts as you navigate. A forced refresh made each of those a real
    /// `/me/tracks/contains` request: one continuously playing track drew seven of them in under
    /// two minutes, all returning the same answer.
    ///
    /// What that costs is picking up a favorite toggled on another device while this track plays.
    /// It is a fair trade — every other list in the app already resolves statuses through the
    /// cache, so this makes the bar consistent rather than uniquely stale — and the real fix is
    /// Spotify's collection change feed, which already arrives over Mercury and is dropped
    /// unread (`plans/single-grant-partner-api.md`, task 12). Polling on view re-appearance was
    /// never going to be the right mechanism for that.
    private func resolveCurrentTrackFavoriteStatusIfNeeded() async {
        guard let trackId = currentTrackId else { return }

        await trackService.ensureFavoriteStatuses(trackIds: [trackId])
    }

    /// Unified volume (0-100 scale).
    /// Uses the remote device's volume when Spotify Connect is active, otherwise local.
    private var currentVolume: Double {
        (playbackViewModel.remoteVolume ?? playbackViewModel.volume) * 100
    }

    private var volumeIconName: String {
        if currentVolume == 0 {
            "speaker.fill"
        } else if currentVolume < 50 {
            "speaker.wave.1.fill"
        } else {
            "speaker.wave.3.fill"
        }
    }

    private func setVolume(_ volume: Double) {
        // Optimistically update remoteVolume for immediate slider feedback
        if playbackViewModel.remoteVolume != nil {
            playbackViewModel.remoteVolume = volume / 100
        }
        playbackViewModel.volume = volume / 100
    }

    /// Whether the device being controlled refuses volume changes.
    ///
    /// Only ever true for a *remote* device: the local player's volume is this app's own, and
    /// nothing can decline it. An iPhone declares it, because iOS will not let one app set
    /// system volume for another — which the app previously discovered by sending the command
    /// and reading `400 DEVICE_DOES_NOT_SUPPORT_COMMAND` off the reply, having already let the
    /// user drag the slider somewhere it would not stay.
    private var volumeRefused: Bool {
        playbackViewModel.remoteVolume != nil && store.activeDevice?.disableVolume == true
    }

    private var volumeControl: some View {
        Button {
            showVolumePopover.toggle()
        } label: {
            Image(systemName: volumeIconName)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showVolumePopover, arrowEdge: .bottom) {
            VStack(spacing: 6) {
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
                    .disabled(volumeRefused)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .opacity(volumeRefused ? 0.5 : 1)

                // A greyed-out slider says "not now"; it does not say the device is the reason.
                if volumeRefused {
                    Text("volume.device_controls_itself \(store.activeDevice?.name ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 180)
                        .multilineTextAlignment(.center)
                }
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
        if let track = currentTrack {
            Menu {
                TrackContextMenu(
                    track: track,
                    currentSection: .queue,
                    selectionId: nil,
                    // The now-playing bar knows the song, never which playlist row it came
                    // from — and with no playlist selected there is nothing to remove from
                    // anyway.
                    itemUid: nil,
                    playbackViewModel: playbackViewModel,
                    showNewPlaylistDialog: $showNewPlaylistDialog,
                    onPlaylistAdded: showSuccessFeedback,
                    onNavigate: exitMiniPlayerIfNeeded,
                )
            } label: {
                Image(systemName: showPlaylistAddedSuccess ? "checkmark.circle.fill" : "ellipsis")
                    .font(.body)
                    .foregroundStyle(showPlaylistAddedSuccess ? .green : .secondary)
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
