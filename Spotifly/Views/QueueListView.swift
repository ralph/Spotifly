//
//  QueueListView.swift
//  Spotifly
//
//  Displays the player's queue, as `PlayerModel.queueEntries` gives it
//

import SwiftUI

extension Notification.Name {
    static let scrollToCurrentTrack = Notification.Name("scrollToCurrentTrack")

    // Toolbar menu actions
    static let showAlbumRemoveConfirmation = Notification.Name("showAlbumRemoveConfirmation")
    static let showArtistUnfollowConfirmation = Notification.Name("showArtistUnfollowConfirmation")
    static let showPlaylistEditDetails = Notification.Name("showPlaylistEditDetails")
    static let showPlaylistCoverPicker = Notification.Name("showPlaylistCoverPicker")
    static let showPlaylistRemoveCoverConfirmation = Notification.Name("showPlaylistRemoveCoverConfirmation")
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
    @Environment(PlayerModel.self) private var player
    @Environment(DeviceService.self) private var deviceService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(TrackService.self) private var trackService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    @State private var scrollPosition = ScrollPosition(idType: Int.self)

    /// Queue item with track and provider info, and the row a double-click plays.
    private struct QueueDisplayItem {
        let track: Track
        let provider: TrackProvider
        let row: PlaybackViewModel.QueueRow
    }

    /// How many of the next tracks the store has metadata for, which the header counts.
    private var nextTracksWithMetadata: Int {
        player.queueEntries.nextTracks.count(where: { store.tracks[$0.trackId] != nil })
    }

    /// Flattened queue with provider info: previous + current + next. A track whose metadata
    /// has not arrived has no row, so each item keeps its index in its own list.
    private var allQueueItems: [QueueDisplayItem] {
        var items: [QueueDisplayItem] = []
        let queue = player.queueEntries

        for (index, entry) in queue.previousTracks.enumerated() {
            if let track = store.tracks[entry.trackId] {
                let row = PlaybackViewModel.QueueRow.previous(index: index, trackUri: track.uri, uid: entry.uid)
                items.append(QueueDisplayItem(track: track, provider: entry.provider, row: row))
            }
        }

        if let entry = queue.currentTrack, let track = store.tracks[entry.trackId] {
            items.append(QueueDisplayItem(track: track, provider: entry.provider, row: .current))
        }

        for (index, entry) in queue.nextTracks.enumerated() {
            if let track = store.tracks[entry.trackId] {
                let row = PlaybackViewModel.QueueRow.next(index: index, trackUri: track.uri, uid: entry.uid)
                items.append(QueueDisplayItem(track: track, provider: entry.provider, row: row))
            }
        }

        return items
    }

    /// The context the queue plays from: its name, and the page the name opens, where it has
    /// one. Read from the player, which says what it plays from with every queue it publishes:
    /// a copy in the store kept the last non-empty one, so a bare list of tracks played under
    /// the name of the album before it.
    ///
    /// The app's own name comes first, as the one it shows everywhere else: the store's, and
    /// for Liked Songs, which plays as a playlist the store has no entry for, the section's.
    /// The player's, from the resolver or the cluster, names the rest, such as a playlist
    /// started on another device or a radio station, which has no page to open.
    private var contextInfo: (route: Route?, name: String)? {
        guard let queue = player.queue, let uri = queue.context else { return nil }

        let route = Route(contextUri: uri)
        let ownName = if let selection = route?.selection {
            store.name(of: selection)
        } else {
            route?.section?.title
        }

        guard let name = ownName ?? queue.contextName else { return nil }
        return (route, name)
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
        .onChange(of: player.queueEntries.currentTrack?.trackId) { _, _ in
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
                if let device = player.activeDevice {
                    playingFromText(device: device)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if player.queueEntries.length > 0 {
                    // Fallback to song count if no active device
                    Text("queue.song_count \(player.queueEntries.length) \(nextTracksWithMetadata)")
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
        let deviceIcon = deviceService.deviceIcon(for: device.type)

        HStack(spacing: 4) {
            if let context = contextInfo {
                Text("queue.playing_from")

                if let route = context.route {
                    Button {
                        navigationCoordinator.navigate(to: route)
                    } label: {
                        Text("queue.context_name \(context.name)")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("queue.context_name \(context.name)")
                }

                Text("queue.on_device")
            } else {
                // A bare list of tracks, or a context nothing names.
                Text("queue.playing_on")
            }

            Image(systemName: deviceIcon)
            Text(device.name)
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
                    if index > 0 {
                        Divider()
                            .padding(.leading, 78)
                    }

                    TrackRow(
                        track: item.track,
                        index: index,
                        currentlyPlayingURI: playbackViewModel.currentTrackUri,
                        currentIndex: player.queueEntries.currentIndex,
                        provider: item.provider,
                        currentSection: .queue,
                        onDoubleTap: {
                            playbackViewModel.play(queueRow: item.row)
                        },
                    )
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
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
        let currentIndex = player.queueEntries.currentIndex
        guard currentIndex < allQueueItems.count else { return }
        withAnimation {
            scrollPosition.scrollTo(id: currentIndex, anchor: .center)
        }
    }
}
