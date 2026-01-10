//
//  AlbumsListView.swift
//  Spotifly
//
//  Displays user's saved albums using normalized store
//

import SwiftUI

struct AlbumsListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Bindable var playbackViewModel: PlaybackViewModel

    // Selection uses album ID, looked up from store
    @Binding var selectedAlbumId: String?

    /// Callback to handle back navigation (sets the pending navigation in LoggedInView)
    var onBack: ((NavigationItem, String?) -> Void)?

    @State private var errorMessage: String?

    /// The ephemeral album being viewed (if not in user's library)
    private var ephemeralAlbum: Album? {
        guard let viewingId = navigationCoordinator.viewingAlbumId,
              !store.userAlbumIds.contains(viewingId),
              let album = store.albums[viewingId]
        else {
            return nil
        }
        return album
    }

    /// Whether we have content to show (either ephemeral album or user albums)
    private var hasContent: Bool {
        ephemeralAlbum != nil || !store.userAlbums.isEmpty
    }

    var body: some View {
        Group {
            if store.albumsPagination.isLoading, !hasContent {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.albums")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_albums")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadAlbums(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("empty.no_albums")
                        .font(.headline)
                    Text("empty.no_albums.description")
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
                        if let album = ephemeralAlbum {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Currently Viewing")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                AlbumRow(
                                    album: album,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: selectedAlbumId == album.id,
                                    onSelect: {
                                        selectedAlbumId = album.id
                                    },
                                )
                            }

                            if !store.userAlbums.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("Your Library")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        }

                        // User's library albums
                        ForEach(store.userAlbums) { album in
                            AlbumRow(
                                album: album,
                                playbackViewModel: playbackViewModel,
                                isSelected: selectedAlbumId == album.id,
                                onSelect: {
                                    // Clear ephemeral state when user selects a library album
                                    navigationCoordinator.viewingAlbumId = nil
                                    navigationCoordinator.clearSectionHistory()
                                    selectedAlbumId = album.id
                                },
                            )
                        }

                        // Load more indicator
                        if store.albumsPagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMoreAlbums()
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadAlbums(forceRefresh: true)
                }
            }
        }
        .task {
            if store.userAlbums.isEmpty, !store.albumsPagination.isLoading {
                await loadAlbums()
            }
            // Always sync selection with viewing album ID (handles navigation from other sections)
            if let viewingId = navigationCoordinator.viewingAlbumId {
                selectedAlbumId = viewingId
            } else if selectedAlbumId == nil, let first = store.userAlbums.first {
                // No ephemeral album, select first user album
                selectedAlbumId = first.id
            }
        }
        .onChange(of: navigationCoordinator.viewingAlbumId) { _, newId in
            // Auto-select the ephemeral album when it's set
            if let id = newId {
                selectedAlbumId = id
            }
        }
        .onChange(of: store.userAlbums) { _, albums in
            if selectedAlbumId == nil, ephemeralAlbum == nil, let first = albums.first {
                selectedAlbumId = first.id
            }
        }
    }

    private func loadAlbums(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            let token = await session.validAccessToken()
            try await albumService.loadUserAlbums(
                accessToken: token,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreAlbums() async {
        do {
            let token = await session.validAccessToken()
            try await albumService.loadMoreAlbums(accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AlbumRow: View {
    let album: Album
    @Bindable var playbackViewModel: PlaybackViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(SpotifySession.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            // Album cover
            if let imageURL = album.imageURL {
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
                            .cornerRadius(6)
                    case .failure:
                        Image(systemName: "square.stack")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "square.stack")
                    .font(.title2)
                    .frame(width: 60, height: 60)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(6)
            }

            // Album info
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(album.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(String(format: String(localized: "metadata.tracks"), album.trackCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let duration = album.formattedDuration {
                        Text("metadata.separator")
                            .foregroundStyle(.secondary)

                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let releaseDate = album.releaseDate {
                        Text("metadata.separator")
                            .foregroundStyle(.secondary)

                        Text(releaseDate.prefix(4))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let albumType = album.albumType {
                        Text("metadata.separator")
                            .foregroundStyle(.secondary)

                        Text(albumType.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Play button
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.play(uriOrUrl: album.uri, accessToken: token)
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
}
