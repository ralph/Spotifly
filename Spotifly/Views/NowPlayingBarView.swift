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
    @Bindable var playbackViewModel: PlaybackViewModel
    @ObservedObject var windowState: WindowState

    @State private var barHeight: CGFloat = 66
    @State private var cachedAlbumArtImage: Image?
    @State private var cachedAlbumArtURL: String?

    /// Whether to show the bar (has queue OR Spotify Connect active)
    private var shouldShowBar: Bool {
        playbackViewModel.queueLength > 0 || store.isSpotifyConnectActive
    }

    // Helper function for time formatting
    private func formatTime(_ milliseconds: UInt32) -> String {
        let totalSeconds = Int(milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        if shouldShowBar {
            VStack(spacing: 0) {
                // Only show divider when not in mini player mode
                if !windowState.isMiniPlayerMode {
                    Divider()
                }

                GeometryReader { geometry in
                    let isCompact = geometry.size.width < 750
                    let isVeryNarrow = geometry.size.width < 600
                    let calculatedHeight: CGFloat = (isCompact && !windowState.isMiniPlayerMode) ? 90 : 66

                    Group {
                        if isCompact {
                            // Compact layout: progress bar at bottom
                            VStack(spacing: 8) {
                                compactTopRow(showVolume: !isVeryNarrow)
                                progressBar
                                    .padding(.horizontal, 8)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, windowState.isMiniPlayerMode ? 4 : 8)
                        } else {
                            // Wide layout: original layout
                            wideLayout
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                    }
                    .onAppear {
                        barHeight = calculatedHeight
                    }
                    .onChange(of: calculatedHeight) { _, newValue in
                        barHeight = newValue
                    }
                }
                .background(windowState.isMiniPlayerMode ? Color(NSColor.windowBackgroundColor) : Color(NSColor.controlBackgroundColor))
                .frame(height: windowState.isMiniPlayerMode ? nil : barHeight)
                .frame(maxHeight: windowState.isMiniPlayerMode ? .infinity : nil)
            }
            .task(id: playbackViewModel.currentTrackId) {
                // Check favorite status when track changes
                let token = await session.validAccessToken()
                await playbackViewModel.checkCurrentTrackFavoriteStatus(accessToken: token)
            }
        }
    }

    // MARK: - Compact Layout

    private func compactTopRow(showVolume: Bool) -> some View {
        HStack(spacing: 12) {
            albumArt(size: 40)

            trackInfo
                .frame(minWidth: 100, alignment: .leading)

            Spacer()

            playbackControls

            Spacer()

            favoriteButton

            queuePosition

            miniPlayerToggle

            if showVolume {
                volumeControl
            }
        }
    }

    // MARK: - Wide Layout

    private var wideLayout: some View {
        HStack(spacing: 16) {
            albumArt(size: 50)

            trackInfo
                .frame(minWidth: 150, alignment: .leading)

            Spacer()

            playbackControls

            Spacer()

            // TimelineView updates at display refresh rate for smooth slider
            TimelineView(.animation(minimumInterval: 0.033)) { _ in
                HStack(spacing: 8) {
                    Text(formatTime(currentPositionMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)

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
                                    playbackViewModel.seek(to: UInt32(newValue))
                                }
                            },
                        ),
                        in: 0 ... Double(max(currentDurationMs, 1)),
                    )
                    .tint(.green)
                    .frame(width: 200)

                    Text(formatTime(currentDurationMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .leading)
                }
            }

            favoriteButton

            queuePosition

            miniPlayerToggle

            volumeControl
        }
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
        Task {
            let token = await session.validAccessToken()
            await connectService.transferToLocal(playbackViewModel: playbackViewModel, accessToken: token)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 16) {
            Button {
                if store.isSpotifyConnectActive {
                    Task {
                        let token = await session.validAccessToken()
                        await connectService.skipToPrevious(accessToken: token)
                    }
                } else {
                    playbackViewModel.previous()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!store.isSpotifyConnectActive && !playbackViewModel.hasPrevious)

            Button {
                if store.isSpotifyConnectActive {
                    Task {
                        let token = await session.validAccessToken()
                        if store.isPlaying {
                            await connectService.pause(accessToken: token)
                        } else {
                            await connectService.resume(accessToken: token)
                        }
                    }
                } else {
                    if playbackViewModel.isPlaying {
                        SpotifyPlayer.pause()
                        playbackViewModel.isPlaying = false
                    } else {
                        SpotifyPlayer.resume()
                        playbackViewModel.isPlaying = true
                    }
                    playbackViewModel.updateNowPlayingInfo()
                }
            } label: {
                let isPlaying = store.isSpotifyConnectActive ? store.isPlaying : playbackViewModel.isPlaying
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Button {
                if store.isSpotifyConnectActive {
                    Task {
                        let token = await session.validAccessToken()
                        await connectService.skipToNext(accessToken: token)
                    }
                } else {
                    playbackViewModel.next()
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
                Text(formatTime(currentPositionMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

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
                                playbackViewModel.seek(to: UInt32(newValue))
                            }
                        },
                    ),
                    in: 0 ... Double(max(currentDurationMs, 1)),
                )
                .tint(.green)

                Text(formatTime(currentDurationMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var queuePosition: some View {
        Text("\(playbackViewModel.currentIndex + 1)/\(playbackViewModel.queueLength)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 50, alignment: .trailing)
    }

    private var favoriteButton: some View {
        Button {
            Task {
                let token = await session.validAccessToken()
                await playbackViewModel.toggleCurrentTrackFavorite(accessToken: token)
            }
        } label: {
            Image(systemName: playbackViewModel.isCurrentTrackFavorited ? "heart.fill" : "heart")
                .font(.body)
                .foregroundStyle(playbackViewModel.isCurrentTrackFavorited ? .red : .secondary)
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
        HStack(spacing: 6) {
            Image(systemName: currentVolume == 0 ? "speaker.fill" : currentVolume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(store.isSpotifyConnectActive ? .green : .secondary)

            Slider(
                value: Binding(
                    get: { currentVolume },
                    set: { setVolume($0) },
                ),
                in: 0 ... 100,
            )
            .tint(.green)
            .frame(width: 80)
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
}
