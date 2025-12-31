//
//  SearchTracksDetailView.swift
//  Spotifly
//
//  Shows all tracks from search results
//

import SwiftUI

struct SearchTracksDetailView: View {
    let tracks: [SearchTrack]
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)

                    Text("All Tracks")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("\(tracks.count) tracks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                // Track list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)

                            if let imageURL = track.imageURL {
                                AsyncImage(url: imageURL) { phase in
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
                                            .frame(width: 40, height: 40)
                                            .background(Color.gray.opacity(0.2))
                                            .cornerRadius(4)
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                            } else {
                                Image(systemName: "music.note")
                                    .frame(width: 40, height: 40)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(4)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.name)
                                    .font(.subheadline)
                                Text("\(track.artistName) • \(track.albumName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(formatDuration(track.durationMs))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            Task {
                                await playbackViewModel.play(
                                    uriOrUrl: track.uri,
                                    accessToken: authResult.accessToken
                                )
                            }
                        }

                        if track.id != tracks.last?.id {
                            Divider()
                                .padding(.leading, 94)
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
