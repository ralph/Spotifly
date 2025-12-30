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
                Divider()

                HStack(spacing: 16) {
                    // Album art thumbnail
                    if let artURL = playbackViewModel.currentAlbumArtURL,
                       !artURL.isEmpty,
                       let url = URL(string: artURL)
                    {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 50, height: 50)
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 50, height: 50)
                                    .cornerRadius(4)
                            case .failure:
                                Image(systemName: "music.note")
                                    .font(.title3)
                                    .frame(width: 50, height: 50)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(4)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "music.note")
                            .font(.title3)
                            .frame(width: 50, height: 50)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }

                    // Track metadata
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
                    .frame(minWidth: 150, alignment: .leading)

                    Spacer()

                    // Playback controls (center)
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

                    Spacer()

                    // Seek bar and time (right side)
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

                    // Queue position
                    Text("\(playbackViewModel.currentIndex + 1)/\(playbackViewModel.queueLength)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
    }
}
