//
//  ArtistsListView.swift
//  Spotifly
//
//  Displays user's followed artists using normalized store
//

import SwiftUI

struct ArtistsListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService
    @Bindable var playbackViewModel: PlaybackViewModel

    // Selection uses artist ID, looked up from store
    @Binding var selectedArtistId: String?

    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.artistsPagination.isLoading, store.userArtists.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.artists")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, store.userArtists.isEmpty {
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
                            await loadArtists(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if store.userArtists.isEmpty {
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
                        ForEach(store.userArtists) { artist in
                            ArtistRow(
                                artist: artist,
                                playbackViewModel: playbackViewModel,
                                isSelected: selectedArtistId == artist.id,
                                onSelect: {
                                    selectedArtistId = artist.id
                                },
                            )
                        }

                        // Load more indicator
                        if store.artistsPagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMoreArtists()
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadArtists(forceRefresh: true)
                }
            }
        }
        .task {
            if store.userArtists.isEmpty, !store.artistsPagination.isLoading {
                await loadArtists()
            }
        }
    }

    private func loadArtists(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            try await artistService.loadUserArtists(
                accessToken: session.accessToken,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreArtists() async {
        do {
            try await artistService.loadMoreArtists(accessToken: session.accessToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ArtistRow: View {
    let artist: Artist
    @Bindable var playbackViewModel: PlaybackViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(SpotifySession.self) private var session

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

                if let followers = artist.followers {
                    Text(String(format: String(localized: "metadata.followers"), formatFollowers(followers)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Play button
            Button {
                Task {
                    await playbackViewModel.play(uriOrUrl: artist.uri, accessToken: session.accessToken)
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
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
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
