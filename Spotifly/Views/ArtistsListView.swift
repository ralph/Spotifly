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
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Bindable var playbackViewModel: PlaybackViewModel

    // Selection uses artist ID, looked up from store
    @Binding var selectedArtistId: String?

    /// Callback to handle back navigation (sets the pending navigation in LoggedInView)
    var onBack: ((NavigationItem, String?) -> Void)?

    @State private var errorMessage: String?

    /// The ephemeral artist being viewed (if not in user's library)
    private var ephemeralArtist: Artist? {
        guard let viewingId = navigationCoordinator.viewingArtistId,
              !store.userArtistIds.contains(viewingId),
              let artist = store.artists[viewingId]
        else {
            return nil
        }
        return artist
    }

    /// Whether we have content to show (either ephemeral artist or user artists)
    private var hasContent: Bool {
        ephemeralArtist != nil || !store.userArtists.isEmpty
    }

    var body: some View {
        Group {
            if store.artistsPagination.isLoading, !hasContent {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.artists")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, !hasContent {
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
            } else if !hasContent {
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
                        // Back button when navigated from another section
                        if let backTitle = navigationCoordinator.previousSectionTitle {
                            Button {
                                if let (section, selectionId) = navigationCoordinator.goBack() {
                                    onBack?(section, selectionId)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.caption.weight(.semibold))
                                    Text("Back to \(backTitle)")
                                        .font(.subheadline)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 8)
                        }

                        // Ephemeral "Currently Viewing" section
                        if let artist = ephemeralArtist {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Currently Viewing")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ArtistRow(
                                    artist: artist,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: selectedArtistId == artist.id,
                                    onSelect: {
                                        selectedArtistId = artist.id
                                    },
                                )
                            }

                            if !store.userArtists.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("Your Library")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        }

                        // User's library artists
                        ForEach(store.userArtists) { artist in
                            ArtistRow(
                                artist: artist,
                                playbackViewModel: playbackViewModel,
                                isSelected: selectedArtistId == artist.id,
                                onSelect: {
                                    // Clear ephemeral state when user selects a library artist
                                    navigationCoordinator.viewingArtistId = nil
                                    navigationCoordinator.clearSectionHistory()
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
            // Always sync selection with viewing artist ID (handles navigation from other sections)
            if let viewingId = navigationCoordinator.viewingArtistId {
                selectedArtistId = viewingId
            } else if selectedArtistId == nil, let first = store.userArtists.first {
                // No ephemeral artist, select first user artist
                selectedArtistId = first.id
            }
        }
        .onChange(of: navigationCoordinator.viewingArtistId) { _, newId in
            // Auto-select the ephemeral artist when it's set
            if let id = newId {
                selectedArtistId = id
            }
        }
        .onChange(of: store.userArtists) { _, artists in
            if selectedArtistId == nil, ephemeralArtist == nil, let first = artists.first {
                selectedArtistId = first.id
            }
        }
    }

    private func loadArtists(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            let token = await session.validAccessToken()
            try await artistService.loadUserArtists(
                accessToken: token,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreArtists() async {
        do {
            let token = await session.validAccessToken()
            try await artistService.loadMoreArtists(accessToken: token)
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
                    let token = await session.validAccessToken()
                    await playbackViewModel.play(uriOrUrl: artist.uri, accessToken: token)
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
