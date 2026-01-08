//
//  FullScreenPlayerView.swift
//  Spotifly
//
//  Full-screen player view for iOS/iPadOS
//  Displays enhanced playback controls, album art, and track information
//

import SwiftUI

struct FullScreenPlayerView: View {
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(\.dismiss) private var dismiss

    // Helper function for time formatting
    private func formatTime(_ milliseconds: UInt32) -> String {
        let totalSeconds = Int(milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [.black.opacity(0.8), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar with close button
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding()
                    }
                }
                .padding(.horizontal)

                Spacer()

                // Album art
                if let artURL = playbackViewModel.currentAlbumArtURL,
                   !artURL.isEmpty,
                   let url = URL(string: artURL)
                {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 300, height: 300)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 350, maxHeight: 350)
                                .cornerRadius(12)
                                .shadow(radius: 20)
                        case .failure:
                            Image(systemName: "music.note")
                                .font(.system(size: 100))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(width: 300, height: 300)
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 100))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 300, height: 300)
                }

                Spacer()

                // Track info
                VStack(spacing: 8) {
                    if let trackName = playbackViewModel.currentTrackName {
                        Text(trackName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }

                    if let artistName = playbackViewModel.currentArtistName {
                        Text(artistName)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                // Progress bar and time
                VStack(spacing: 8) {
                    Slider(
                        value: Binding<Double>(
                            get: { Double(playbackViewModel.currentPositionMs) },
                            set: { newValue in
                                let positionMs = UInt32(max(0, newValue))
                                do {
                                    try SpotifyPlayer.seek(positionMs: positionMs)
                                    playbackViewModel.currentPositionMs = positionMs
                                    playbackViewModel.updateNowPlayingInfo()
                                } catch {
                                    playbackViewModel.errorMessage = error.localizedDescription
                                }
                            }
                        ),
                        in: Double(0)...Double(max(playbackViewModel.trackDurationMs, 1))
                    )
                    .tint(.green)

                    HStack {
                        Text(formatTime(playbackViewModel.currentPositionMs))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()

                        Spacer()

                        Text(formatTime(playbackViewModel.trackDurationMs))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                // Playback controls
                HStack(spacing: 40) {
                    Button {
                        playbackViewModel.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    }
                    .disabled(!playbackViewModel.hasPrevious)

                    Button {
                        if playbackViewModel.isPlaying {
                            SpotifyPlayer.pause()
                            playbackViewModel.isPlaying = false
                        } else {
                            SpotifyPlayer.resume()
                            playbackViewModel.isPlaying = true
                        }
                        playbackViewModel.updateNowPlayingInfo()
                    } label: {
                        Image(systemName: playbackViewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.white)
                    }

                    Button {
                        playbackViewModel.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    }
                    .disabled(!playbackViewModel.hasNext)
                }
                .padding(.vertical, 24)

                // Additional controls
                HStack(spacing: 32) {
                    // Favorite button
                    Button {
                        Task {
                            await playbackViewModel.toggleCurrentTrackFavorite(accessToken: authResult.accessToken)
                        }
                    } label: {
                        Image(systemName: playbackViewModel.isCurrentTrackFavorited ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(playbackViewModel.isCurrentTrackFavorited ? .red : .white.opacity(0.7))
                    }

                    Spacer()

                    // Queue position
                    Text("\(playbackViewModel.currentIndex + 1)/\(playbackViewModel.queueLength)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()

                    // Volume control
                    HStack(spacing: 12) {
                        Image(systemName: playbackViewModel.volume == 0 ? "speaker.fill" : playbackViewModel.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))

                        Slider(
                            value: $playbackViewModel.volume,
                            in: 0 ... 1
                        )
                        .tint(.green)
                        .frame(width: 100)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }
}
