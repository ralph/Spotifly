//
//  TrackDetailView.swift
//  Spotifly
//
//  Shows details for a single track search result
//

import SwiftUI

struct TrackDetailView: View {
    let track: SearchTrack
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Album art
            if let imageURL = track.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 200, height: 200)
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 200, height: 200)
                            .cornerRadius(8)
                            .shadow(radius: 10)
                    case .failure:
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .frame(width: 200, height: 200)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .frame(width: 200, height: 200)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
            }

            // Track info
            VStack(spacing: 8) {
                Text(track.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                Text(track.artistName)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(track.albumName)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                Text(formatDuration(track.durationMs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Play button
            Button {
                Task {
                    await playbackViewModel.play(
                        uriOrUrl: track.uri,
                        accessToken: authResult.accessToken,
                    )
                }
            } label: {
                Label("playback.play_track", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
