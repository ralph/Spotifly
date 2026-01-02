//
//  NowPlayingBarView.swift
//  Spotifly
//
//  Persistent now playing bar at the bottom of the window
//

import SwiftUI

struct NowPlayingBarView: View {
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel
    @ObservedObject var windowState: WindowState

    // Helper function for time formatting
    private func formatTime(_ milliseconds: UInt32) -> String {
        let totalSeconds = Int(milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        if playbackViewModel.queueLength > 0 {
            VStack(spacing: 0) {
                // Only show divider when not in mini player mode
                if !windowState.isMiniPlayerMode {
                    Divider()
                }

                GeometryReader { geometry in
                    let isCompact = geometry.size.width < 750
                    let isVeryNarrow = geometry.size.width < 600
                    let barHeight: CGFloat = (isCompact && !windowState.isMiniPlayerMode) ? 90 : 66

                    Group {
                        if isCompact {
                            // Compact layout: progress bar at bottom
                            VStack(spacing: 8) {
                                compactTopRow(showVolume: !isVeryNarrow)
                                progressBar
                                    .padding(.horizontal, 8)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, windowState.isMiniPlayerMode ? 4 : 8)
                            .padding(.bottom, 8)
                        } else {
                            // Wide layout: original layout
                            wideLayout
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                    }
                    .frame(height: barHeight)
                }
                .background(Color(NSColor.controlBackgroundColor))
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

            HStack(spacing: 8) {
                Text(formatTime(playbackViewModel.currentPositionMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { Double(playbackViewModel.currentPositionMs) },
                        set: { newValue in
                            let positionMs = UInt32(newValue)
                            do {
                                try SpotifyPlayer.seek(positionMs: positionMs)
                                playbackViewModel.currentPositionMs = positionMs

                                if playbackViewModel.isPlaying {
                                    playbackViewModel.playbackStartTime = Date().addingTimeInterval(-Double(positionMs) / 1000.0)
                                }

                                playbackViewModel.updateNowPlayingInfo()
                            } catch {
                                playbackViewModel.errorMessage = error.localizedDescription
                            }
                        },
                    ),
                    in: 0 ... Double(max(playbackViewModel.trackDurationMs, 1)),
                )
                .tint(.green)
                .frame(width: 200)

                Text(formatTime(playbackViewModel.trackDurationMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
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
            if let artURL = playbackViewModel.currentAlbumArtURL,
               !artURL.isEmpty,
               let url = URL(string: artURL)
            {
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
                            .cornerRadius(4)
                    case .failure:
                        Image(systemName: "music.note")
                            .font(.title3)
                            .frame(width: size, height: size)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.title3)
                    .frame(width: size, height: size)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
        }
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let trackName = playbackViewModel.currentTrackName {
                Text(trackName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            if let artistName = playbackViewModel.currentArtistName {
                Text(artistName)
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
                    SpotifyPlayer.pause()
                    playbackViewModel.isPlaying = false
                    playbackViewModel.playbackStartTime = nil
                } else {
                    SpotifyPlayer.resume()
                    playbackViewModel.isPlaying = true
                    if playbackViewModel.currentPositionMs > 0 {
                        playbackViewModel.playbackStartTime = Date().addingTimeInterval(-Double(playbackViewModel.currentPositionMs) / 1000.0)
                    } else {
                        playbackViewModel.playbackStartTime = Date()
                    }
                }
                playbackViewModel.updateNowPlayingInfo()
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

    private var progressBar: some View {
        HStack(spacing: 8) {
            Text(formatTime(playbackViewModel.currentPositionMs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Slider(
                value: Binding(
                    get: { Double(playbackViewModel.currentPositionMs) },
                    set: { newValue in
                        let positionMs = UInt32(newValue)
                        do {
                            try SpotifyPlayer.seek(positionMs: positionMs)
                            playbackViewModel.currentPositionMs = positionMs

                            if playbackViewModel.isPlaying {
                                playbackViewModel.playbackStartTime = Date().addingTimeInterval(-Double(positionMs) / 1000.0)
                            }

                            playbackViewModel.updateNowPlayingInfo()
                        } catch {
                            playbackViewModel.errorMessage = error.localizedDescription
                        }
                    },
                ),
                in: 0 ... Double(max(playbackViewModel.trackDurationMs, 1)),
            )
            .tint(.green)

            Text(formatTime(playbackViewModel.trackDurationMs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
                await playbackViewModel.toggleCurrentTrackFavorite(accessToken: authResult.accessToken)
            }
        } label: {
            Image(systemName: playbackViewModel.isCurrentTrackFavorited ? "heart.fill" : "heart")
                .font(.body)
                .foregroundStyle(playbackViewModel.isCurrentTrackFavorited ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .task(id: playbackViewModel.currentTrackId) {
            // Check favorite status when track changes
            await playbackViewModel.checkCurrentTrackFavoriteStatus(accessToken: authResult.accessToken)
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: playbackViewModel.volume == 0 ? "speaker.fill" : playbackViewModel.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(
                value: $playbackViewModel.volume,
                in: 0 ... 1,
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
