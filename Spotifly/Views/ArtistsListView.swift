//
//  ArtistsListView.swift
//  Spotifly
//
//  Displays user's followed artists using normalized store
//

import SwiftUI

struct ArtistsListView: View {
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Bindable var playbackViewModel: PlaybackViewModel

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
                    LazyVStack(spacing: 0) {
                        // Back button when navigated from another section
                        if ephemeralArtist != nil, let backTitle = navigationCoordinator.backNavigationTitle {
                            Button {
                                navigationCoordinator.navigateBackward()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.caption.weight(.semibold))
                                    Text("nav.back_to \(backTitle)")
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
                                Text("nav.currently_viewing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ArtistRow(
                                    artist: artist,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: navigationCoordinator.selectedArtistId == artist.id,
                                    onSelect: {
                                        navigationCoordinator.selectArtist(artist.id)
                                    },
                                )
                            }

                            if !store.userArtists.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("nav.your_library")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        }

                        // User's library artists
                        ForEach(store.userArtists.enumerated(), id: \.element.id) { index, artist in
                            VStack(spacing: 0) {
                                ArtistRow(
                                    artist: artist,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: navigationCoordinator.selectedArtistId == artist.id,
                                    onSelect: {
                                        navigationCoordinator.selectArtist(artist.id)
                                    },
                                )

                                if index < store.userArtists.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
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
            selectFirstArtistIfNeeded()
        }
        .onChange(of: store.userArtists) { _, _ in
            selectFirstArtistIfNeeded()
        }
    }

    /// The section always shows a detail, so entering it lands on the first artist. The
    /// coordinator is told at this call site that the step is automatic, so it replaces the
    /// route rather than recording a history entry the user never asked for.
    private func selectFirstArtistIfNeeded() {
        guard navigationCoordinator.selectedArtistId == nil, let first = store.userArtists.first else { return }
        navigationCoordinator.selectArtist(first.id, recordsHistory: false)
    }

    private func loadArtists(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            try await artistService.loadUserArtists(forceRefresh: forceRefresh)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreArtists() async {
        do {
            try await artistService.loadMoreArtists()
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
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    private let imageSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            // Artist image (circular)
            if let url = artist.images.url(for: imageSize, scale: displayScale) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        artistPlaceholder
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: imageSize, height: imageSize)
                            .clipShape(.circle)
                    case .failure:
                        artistPlaceholder
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                artistPlaceholder
            }

            // Artist name
            Text(artist.name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .overlay(alignment: .trailing) {
            if isHovering {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        await playbackViewModel.play(uriOrUrl: artist.uri, accessToken: token)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(playbackViewModel.isLoading)
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var artistPlaceholder: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: imageSize, height: imageSize)
            .background(Color.gray.opacity(0.15))
            .clipShape(Circle())
    }
}
