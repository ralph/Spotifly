//
//  TrackInfoView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct TrackInfoView: View {
    let track: TrackMetadata
    let accessToken: String
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Album artwork
            AsyncImage(url: track.albumImageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: 200, height: 200)
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                case .failure:
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                        .frame(width: 200, height: 200)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                @unknown default:
                    EmptyView()
                }
            }

            // Play/Pause button
            Button {
                Task {
                    await playbackViewModel.togglePlayPause(trackId: track.id, accessToken: accessToken)
                }
            } label: {
                Group {
                    if playbackViewModel.isLoading {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: isCurrentTrackPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                    }
                }
                .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .disabled(playbackViewModel.isLoading)

            if let error = playbackViewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            // Track info
            VStack(spacing: 4) {
                Text(track.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(track.artistName)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(track.albumName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(track.durationFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            // Track ID for reference
            GroupBox {
                HStack {
                    Text("Track ID:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(track.id)
                        .font(.caption)
                        .monospaced()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("spotify:track:\(track.id)", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy track URI")
                }
            }
        }
        .padding()
    }

    private var isCurrentTrackPlaying: Bool {
        playbackViewModel.isPlaying && playbackViewModel.currentTrackId == track.id
    }
}
