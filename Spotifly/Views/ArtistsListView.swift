//
//  ArtistsListView.swift
//  Spotifly
//
//  Displays user's followed artists
//

import SwiftUI

struct ArtistsListView: View {
    let authResult: SpotifyAuthResult
    @Bindable var artistsViewModel: ArtistsViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    @Binding var selectedArtist: ArtistSimplified?

    var body: some View {
        Group {
            if artistsViewModel.isLoading, artistsViewModel.artists.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.artists")
                        .foregroundStyle(.secondary)
                }
            } else if let error = artistsViewModel.errorMessage, artistsViewModel.artists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_artists")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await artistsViewModel.loadArtists(accessToken: authResult.accessToken)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if artistsViewModel.artists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "person.2")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("empty.no_artists")
                        .font(.headline)
                    Text("empty.no_artists.description")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(artistsViewModel.artists) { artist in
                            ArtistRow(
                                artist: artist,
                                playbackViewModel: playbackViewModel,
                                accessToken: authResult.accessToken,
                                selectedArtist: $selectedArtist,
                            )
                        }

                        // Load more indicator
                        if artistsViewModel.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await artistsViewModel.loadMoreIfNeeded(accessToken: authResult.accessToken)
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await artistsViewModel.refresh(accessToken: authResult.accessToken)
                }
            }
        }
        .task {
            if artistsViewModel.artists.isEmpty, !artistsViewModel.isLoading {
                await artistsViewModel.loadArtists(accessToken: authResult.accessToken)
            }
        }
    }
}

struct ArtistRow: View {
    let artist: ArtistSimplified
    @Bindable var playbackViewModel: PlaybackViewModel
    let accessToken: String
    @Binding var selectedArtist: ArtistSimplified?

    var body: some View {
        HStack(spacing: 12) {
            // Artist image
            if let imageURL = artist.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 60, height: 60)
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                    case .failure:
                        Image(systemName: "person.circle")
                            .font(.system(size: 60))
                            .foregroundStyle(.gray.opacity(0.5))
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "person.circle")
                    .font(.system(size: 60))
                    .foregroundStyle(.gray.opacity(0.5))
            }

            // Artist info
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(1)

                if !artist.genres.isEmpty {
                    Text(artist.genres.prefix(2).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(String(format: String(localized: "metadata.followers"), formatFollowers(artist.followers)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Play button
            Button {
                Task {
                    await playbackViewModel.play(uriOrUrl: artist.uri, accessToken: accessToken)
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(playbackViewModel.isLoading)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedArtist = artist
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
