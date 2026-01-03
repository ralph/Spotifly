//
//  ArtistDetailView.swift
//  Spotifly
//
//  Shows details for an artist search result with top tracks
//

import SwiftUI

struct ArtistDetailView: View {
    let artist: SearchArtist
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var topTracks: [SearchTrack] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Artist image and metadata
                VStack(spacing: 16) {
                    if let imageURL = artist.imageURL {
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
                                    .clipShape(Circle())
                                    .shadow(radius: 10)
                            case .failure:
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .frame(width: 200, height: 200)
                                    .foregroundStyle(.gray.opacity(0.3))
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 200, height: 200)
                            .foregroundStyle(.gray.opacity(0.3))
                    }

                    VStack(spacing: 8) {
                        Text(artist.name)
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)

                        if !artist.genres.isEmpty {
                            Text(artist.genres.prefix(3).joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Text(String(format: String(localized: "metadata.followers"), formatFollowers(artist.followers)))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    // Play Top Tracks button
                    Button {
                        playAllTopTracks()
                    } label: {
                        Label("playback.play_top_tracks", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(topTracks.isEmpty)
                }
                .padding(.top, 24)

                // Top Tracks
                if isLoading {
                    ProgressView("loading.top_tracks")
                        .padding()
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("section.top_tracks")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(topTracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(
                                    track: track.toTrackRowData(),
                                    index: index,
                                    currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                    playbackViewModel: playbackViewModel,
                                    accessToken: authResult.accessToken,
                                )

                                if track.id != topTracks.last?.id {
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
        }
        .task {
            await loadTopTracks()
        }
    }

    private func loadTopTracks() async {
        guard topTracks.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            topTracks = try await SpotifyAPI.fetchArtistTopTracks(
                accessToken: authResult.accessToken,
                artistId: artist.id,
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func playAllTopTracks() {
        Task {
            await playbackViewModel.playTracks(
                topTracks.map(\.uri),
                accessToken: authResult.accessToken,
            )
        }
    }

    private func formatFollowers(_ count: Int) -> String {
        if count >= 1_000_000 {
            String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1000 {
            String(format: "%.1fK", Double(count) / 1000.0)
        } else {
            "\(count)"
        }
    }
}
