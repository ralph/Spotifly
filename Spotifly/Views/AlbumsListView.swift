//
//  AlbumsListView.swift
//  Spotifly
//
//  Displays user's saved albums using normalized store
//

import SwiftUI

struct AlbumsListView: View {
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Bindable var playbackViewModel: PlaybackViewModel

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
                    LazyVStack(spacing: 0) {
                        // Back button when navigated from another section
                        if ephemeralAlbum != nil, let backTitle = navigationCoordinator.backNavigationTitle {
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
                        if let album = ephemeralAlbum {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("nav.currently_viewing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                AlbumRow(
                                    album: album,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: navigationCoordinator.selectedAlbumId == album.id,
                                    onSelect: {
                                        navigationCoordinator.selectAlbum(album.id)
                                    },
                                )
                            }

                            if !store.userAlbums.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("nav.your_library")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        }

                        // User's library albums
                        ForEach(store.userAlbums.enumerated(), id: \.element.id) { index, album in
                            VStack(spacing: 0) {
                                AlbumRow(
                                    album: album,
                                    playbackViewModel: playbackViewModel,
                                    isSelected: navigationCoordinator.selectedAlbumId == album.id,
                                    onSelect: {
                                        navigationCoordinator.selectAlbum(album.id)
                                    },
                                )

                                if index < store.userAlbums.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
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
            selectFirstAlbumIfNeeded()
        }
        .onChange(of: store.userAlbums) { _, _ in
            selectFirstAlbumIfNeeded()
        }
    }

    /// The section always shows a detail, so entering it lands on the first album. The
    /// coordinator is told at this call site that the step is automatic, so it replaces the
    /// route rather than recording a history entry the user never asked for.
    private func selectFirstAlbumIfNeeded() {
        guard navigationCoordinator.selectedAlbumId == nil, let first = store.userAlbums.first else { return }
        navigationCoordinator.selectAlbum(first.id, recordsHistory: false)
    }

    private func loadAlbums(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            try await albumService.loadUserAlbums(forceRefresh: forceRefresh)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreAlbums() async {
        do {
            try await albumService.loadMoreAlbums()
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
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    private let imageSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            // Album cover
            if let url = album.images.url(for: imageSize, scale: displayScale) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        albumPlaceholder
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: imageSize, height: imageSize)
                            .clipShape(.rect(cornerRadius: 4))
                    case .failure:
                        albumPlaceholder
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                albumPlaceholder
            }

            // Album name
            Text(album.name)
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
                        await playbackViewModel.play(uriOrUrl: album.uri, accessToken: token)
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

    private var albumPlaceholder: some View {
        Image(systemName: "square.stack")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: imageSize, height: imageSize)
            .background(Color.gray.opacity(0.15))
            .clipShape(.rect(cornerRadius: 4))
    }
}
