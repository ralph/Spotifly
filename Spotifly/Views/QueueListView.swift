//
//  QueueListView.swift
//  Spotifly
//
//  Displays current playback queue (real-time updates via Spirc/Mercury)
//

import SwiftUI

extension Notification.Name {
    static let scrollToCurrentTrack = Notification.Name("scrollToCurrentTrack")

    // Toolbar menu actions
    static let showAlbumRemoveConfirmation = Notification.Name("showAlbumRemoveConfirmation")
    static let showArtistUnfollowConfirmation = Notification.Name("showArtistUnfollowConfirmation")
    static let showPlaylistEditDetails = Notification.Name("showPlaylistEditDetails")
    static let showPlaylistDeleteConfirmation = Notification.Name("showPlaylistDeleteConfirmation")
    static let showPlaylistUnfollowConfirmation = Notification.Name("showPlaylistUnfollowConfirmation")
}

extension View {
    /// Runs `action` when one of the toolbar menu actions above is addressed to this view's
    /// entity.
    ///
    /// The toolbar has no way to reach the open detail view but a notification, and every
    /// detail view asks the same question of the ones it receives: is this one for me? The
    /// entity id travels as the notification's object.
    func onToolbarAction(
        _ name: Notification.Name,
        addressedTo id: String,
        perform action: @escaping () -> Void,
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { notification in
            guard notification.object as? String == id else { return }
            action()
        }
    }
}

struct QueueListView: View {
    @Environment(AppStore.self) private var store
    @Environment(DeviceService.self) private var deviceService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(TrackService.self) private var trackService
    let playbackViewModel: PlaybackViewModel

    @State private var scrollPosition = ScrollPosition(idType: Int.self)

    /// Queue item with track and provider info
    private struct QueueDisplayItem {
        let track: Track
        let provider: TrackProvider
    }

    /// Flattened queue with provider info: previous + current + next
    private var allQueueItems: [QueueDisplayItem] {
        var items: [QueueDisplayItem] = []

        // Previous tracks
        for entry in store.queue.previousTracks {
            if let track = store.tracks[entry.trackId] {
                items.append(QueueDisplayItem(track: track, provider: entry.provider))
            }
        }

        // Current track
        if let entry = store.queue.currentTrack, let track = store.tracks[entry.trackId] {
            items.append(QueueDisplayItem(track: track, provider: entry.provider))
        }

        // Next tracks
        for entry in store.queue.nextTracks {
            if let track = store.tracks[entry.trackId] {
                items.append(QueueDisplayItem(track: track, provider: entry.provider))
            }
        }

        return items
    }

    /// Context info parsed from context URI
    private var contextInfo: (type: ContextType, id: String, name: String)? {
        guard let uri = store.queue.contextUri else { return nil }

        if uri.hasPrefix("spotify:album:") {
            let id = String(uri.dropFirst("spotify:album:".count))
            if let album = store.albums[id] {
                return (.album, id, album.name)
            }
        } else if uri.hasPrefix("spotify:playlist:") {
            let id = String(uri.dropFirst("spotify:playlist:".count))
            if let playlist = store.playlists[id] {
                return (.playlist, id, playlist.name)
            }
        } else if uri.hasPrefix("spotify:artist:") {
            let id = String(uri.dropFirst("spotify:artist:".count))
            if let artist = store.artists[id] {
                return (.artist, id, artist.name)
            }
        }

        return nil
    }

    private enum ContextType {
        case album, playlist, artist
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header
            queueHeader

            Divider()

            // Scrollable content
            if allQueueItems.isEmpty {
                emptyView
            } else {
                normalModeContent
            }
        }
        .task {
            await syncQueueFavoriteStatuses()
        }
        .onChange(of: store.queue.currentTrack?.trackId) { _, _ in
            Task {
                await syncQueueFavoriteStatuses()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToCurrentTrack)) { _ in
            scrollToCurrentTrack()
        }
    }

    // MARK: - Header

    private var queueHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("queue.title")
                    .font(.headline)

                // "Playing from X on Y" subtitle
                if let device = store.activeDevice {
                    playingFromText(device: device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if store.queueLength > 0 {
                    // Fallback to song count if no active device
                    Text("queue.song_count \(store.queueLength) \(store.nextTrackEntities.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func playingFromText(device: Device) -> some View {
        let context = contextInfo
        let contextName = context?.name ?? String(localized: "queue.title")
        let deviceIcon = deviceService.deviceIcon(for: device.type)

        HStack(spacing: 4) {
            Text("queue.playing_from")

            if let context {
                // Context name is a tappable link
                Button {
                    navigateToContext(type: context.type, id: context.id)
                } label: {
                    Text("\"\(contextName)\"")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            } else {
                Text("\"\(contextName)\"")
            }

            Text("queue.on_device")
            Image(systemName: deviceIcon)
            Text(device.name)
        }
    }

    private func navigateToContext(type: ContextType, id: String) {
        switch type {
        case .album:
            navigationCoordinator.navigateToAlbumSection(albumId: id)
        case .playlist:
            navigationCoordinator.navigateToPlaylistSection(playlistId: id)
        case .artist:
            navigationCoordinator.navigateToArtistSection(artistId: id)
        }
    }

    private func syncQueueFavoriteStatuses() async {
        let trackIds = allQueueItems.map(\.track.id)
        guard !trackIds.isEmpty else { return }

        await trackService.ensureFavoriteStatuses(trackIds: trackIds)
    }

    // MARK: - Normal Mode Content

    private var normalModeContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(allQueueItems.enumerated(), id: \.offset) { index, item in
                    TrackRow(
                        track: item.track,
                        index: index,
                        currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                        currentIndex: store.currentIndex,
                        provider: item.provider,
                        playbackViewModel: playbackViewModel,
                        currentSection: .queue,
                        onDoubleTap: {
                            if let contextUri = store.queue.contextUri {
                                await playbackViewModel.play(
                                    uriOrUrl: contextUri,
                                    trackIndex: index,
                                )
                            } else {
                                await playbackViewModel.play(uriOrUrl: item.track.uri)
                            }
                        },
                    )
                    .id(index)

                    if index < allQueueItems.count - 1 {
                        Divider()
                            .padding(.leading, 78)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .contentMargins(.bottom, 100)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("empty.queue_empty")
                .font(.headline)
            Text("empty.queue_empty.description")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    // MARK: - Navigation

    private func scrollToCurrentTrack() {
        guard store.currentIndex < allQueueItems.count else { return }
        withAnimation {
            scrollPosition.scrollTo(id: store.currentIndex, anchor: .center)
        }
    }
}
