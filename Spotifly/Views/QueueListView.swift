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
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    /// The queue as table rows, numbered over the whole queue: previous, current, next, beside
    /// the row of the queue a double-click on each plays, at the same index. A track whose
    /// metadata has not arrived has no row.
    ///
    /// A row is named by its uid where it has one, which stays with it as the queue moves on,
    /// so a skip shifts no ids and the rows keep their covers, as the inspector's do.
    private func queueRows() -> (rows: [TrackTableRow], plays: [PlaybackViewModel.QueueRow], currentRowId: String?) {
        let queue = player.queueEntries
        var rows: [TrackTableRow] = []
        var plays: [PlaybackViewModel.QueueRow] = []
        var currentRowId: String?
        var usedIds: Set<String> = []

        func append(_ entry: QueueEntry, _ track: Track, _ play: PlaybackViewModel.QueueRow) {
            var id: String = switch play {
            case let .previous(index, _, _): entry.uid ?? "p\(index)"
            case .current: entry.uid ?? "current"
            case let .next(index, _, _): entry.uid ?? "n\(index)"
            }
            // A context repeating wraps into the next tracks with the uids of rows already
            // listed; a table needs every id once.
            if !usedIds.insert(id).inserted {
                id += "#\(rows.count)"
                usedIds.insert(id)
            }
            if case .current = play {
                currentRowId = id
            }
            let isPast = if case .previous = play {
                true
            } else {
                false
            }
            rows.append(TrackTableRow(
                id: id,
                number: rows.count + 1,
                track: track,
                isDimmed: isPast || entry.provider == .unavailable,
                tag: entry.provider.tag,
            ))
            plays.append(play)
        }

        for (index, entry) in queue.previousTracks.enumerated() {
            if let track = store.tracks[entry.trackId] {
                append(entry, track, .previous(index: index, trackUri: track.uri, uid: entry.uid))
            }
        }
        if let entry = queue.currentTrack, let track = store.tracks[entry.trackId] {
            append(entry, track, .current)
        }
        for next in queue.nextRows(in: store.tracks) {
            append(next.entry, next.track, next.row)
        }
        return (rows, plays, currentRowId)
    }

    var body: some View {
        let queue = queueRows()

        VStack(alignment: .leading, spacing: 0) {
            QueueHeader()

            if queue.rows.isEmpty {
                emptyView
            } else {
                // The table is not sortable, so a row's number is its place in `plays`.
                TrackTable(rows: queue.rows, currentSection: .queue, sortable: false, currentRowId: queue.currentRowId) { row in
                    playbackViewModel.play(queueRow: queue.plays[row.number - 1])
                }
            }
        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Warteschlange", the counts, and where the queue plays from. A view of its own, so the device
/// reports it reads, a volume change among them, redraw it and not the table.
private struct QueueHeader: View {
    @Environment(AppStore.self) private var store
    @Environment(PlayerModel.self) private var player
    @Environment(DeviceService.self) private var deviceService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

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
        let queue = player.queueEntries

        VStack(alignment: .leading, spacing: 4) {
            Text("queue.title")
                .font(.largeTitle.bold())

            if queue.length > 0 {
                Text(verbatim: metadataLine(
                    localizedNumberString("metadata.tracks", queue.length),
                    String(localized: "queue.upcoming \(queue.nextTracks.count)"),
                ))
                .foregroundStyle(.secondary)
            }

            // "Playing from X on Y"
            if let device = player.activeDevice {
                playingFromText(device: device)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                            .foregroundStyle(.tint)
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
}

private extension TrackProvider {
    /// The tag a queue row shows: Q queued by hand, C from the context, A autoplay; none for
    /// a track the player could not name.
    var tag: String? {
        switch self {
        case .queue: "Q"
        case .context: "C"
        case .autoplay: "A"
        case .unavailable: nil
        }
    }
}
