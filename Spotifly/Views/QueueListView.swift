//
//  QueueListView.swift
//  Spotifly
//
//  Displays current playback queue with edit mode for reordering and removing tracks
//

import SwiftUI
import UniformTypeIdentifiers

struct QueueListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(QueueService.self) private var queueService
    @Bindable var playbackViewModel: PlaybackViewModel

    // Edit mode state
    @State private var isEditing = false
    @State private var draggedIndex: Int?
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showClearConfirmation = false

    /// Currently playing index from store
    private var currentIndex: Int {
        store.currentIndex
    }

    /// Unplayed queue items (after current index)
    private var unplayedItems: [(index: Int, item: QueueItem)] {
        store.queueItems.enumerated()
            .filter { $0.offset > currentIndex }
            .map { (index: $0.offset, item: $0.element) }
    }

    /// Total song count for header
    private var totalSongCount: Int {
        store.queueItems.count
    }

    /// Unplayed song count for header
    private var unplayedSongCount: Int {
        max(0, store.queueItems.count - currentIndex - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header
            queueHeader

            Divider()

            // Scrollable content
            if let error = store.queueErrorMessage {
                errorView(error)
            } else if store.queueItems.isEmpty {
                emptyView
            } else if isEditing {
                editModeContent
            } else {
                normalModeContent
            }
        }
        .task {
            let token = await session.validAccessToken()
            if store.isSpotifyConnectActive {
                await queueService.loadConnectQueue(accessToken: token)
            } else {
                queueService.loadQueue()
            }
            await queueService.loadFavorites(accessToken: token)
        }
        .onChange(of: store.currentIndex) { oldIndex, newIndex in
            // When player advances during editing, exit edit mode if no more unplayed tracks
            if isEditing, newIndex > oldIndex {
                if unplayedItems.isEmpty {
                    isEditing = false
                }
            }
        }
    }

    // MARK: - Header

    private var queueHeader: some View {
        HStack(spacing: 12) {
            // Song count
            VStack(alignment: .leading, spacing: 2) {
                Text("queue.title")
                    .font(.headline)
                if totalSongCount > 0 {
                    Text("queue.song_count \(totalSongCount) \(unplayedSongCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Scroll to current button
            Button {
                scrollToCurrentTrack()
            } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .buttonStyle(.bordered)
            .disabled(store.queueItems.isEmpty || isEditing)
            .help("queue.scroll_to_current")

            // Clear queue button - disabled in Connect mode (can't modify remote queue)
            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(unplayedItems.isEmpty || store.isSpotifyConnectActive)
            .help("queue.clear")
            .confirmationDialog(
                "queue.clear.confirm.title",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible,
            ) {
                Button("queue.clear.confirm.action", role: .destructive) {
                    clearQueue()
                }
                Button("action.cancel", role: .cancel) {}
            } message: {
                Text("queue.clear.confirm.message \(unplayedSongCount)")
            }

            // Edit/Done button - disabled in Connect mode (can't modify remote queue)
            Button {
                if isEditing {
                    exitEditMode()
                } else {
                    enterEditMode()
                }
            } label: {
                Text(isEditing ? "action.done" : "action.edit")
            }
            .buttonStyle(.borderedProminent)
            .disabled((unplayedItems.isEmpty && !isEditing) || store.isSpotifyConnectActive)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Normal Mode Content

    private var normalModeContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.queueItems.enumerated()), id: \.offset) { index, item in
                        let trackData = item.toTrackRowData()
                        TrackRow(
                            track: trackData,
                            index: index,
                            currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                            currentIndex: playbackViewModel.currentIndex,
                            playbackViewModel: playbackViewModel,
                            doubleTapBehavior: .jumpToQueueIndex,
                        )
                        .id(index)

                        if index < store.queueItems.count - 1 {
                            Divider()
                                .padding(.leading, 78)
                        }
                    }
                }
            }
            .refreshable {
                let token = await session.validAccessToken()
                if store.isSpotifyConnectActive {
                    await queueService.loadConnectQueue(accessToken: token)
                } else {
                    queueService.refresh()
                }
                await queueService.loadFavorites(accessToken: token)
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    // MARK: - Edit Mode Content

    private var editModeContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(unplayedItems, id: \.index) { index, item in
                    EditQueueItemRow(item: item) {
                        removeItem(at: index)
                    }
                    .opacity(draggedIndex == index ? 0.5 : 1.0)
                    .onDrag {
                        draggedIndex = index
                        return NSItemProvider(object: "\(index)" as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: QueueDropDelegate(
                            targetIndex: index,
                            draggedIndex: $draggedIndex,
                            onMove: { from, to in
                                moveItem(from: from, to: to)
                            },
                        ),
                    )

                    if index < store.queueItems.count - 1 {
                        Divider()
                            .padding(.leading, 94)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Error and Empty States

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("error.load_queue")
                .font(.headline)
            Text(error)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("action.try_again") {
                queueService.loadQueue()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

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

    // MARK: - Edit Mode Actions

    private func enterEditMode() {
        isEditing = true
    }

    private func exitEditMode() {
        isEditing = false
        draggedIndex = nil
    }

    private func removeItem(at queueIndex: Int) {
        do {
            try queueService.removeFromQueue(at: queueIndex)
            // Queue is refreshed by the service, UI updates automatically
            // If no more unplayed items, exit edit mode
            if unplayedItems.isEmpty {
                exitEditMode()
            }
        } catch {
            playbackViewModel.errorMessage = String(localized: "error.remove_from_queue")
        }
    }

    private func moveItem(from: Int, to: Int) {
        guard from != to else { return }
        do {
            try queueService.moveQueueItem(from: from, to: to)
            // Queue is refreshed by the service, UI updates automatically
        } catch {
            playbackViewModel.errorMessage = String(localized: "error.reorder_queue")
        }
    }

    private func clearQueue() {
        do {
            try queueService.clearUpcomingQueue()
            if isEditing {
                exitEditMode()
            }
        } catch {
            playbackViewModel.errorMessage = String(localized: "error.clear_queue")
        }
    }

    private func scrollToCurrentTrack() {
        guard currentIndex < store.queueItems.count else { return }
        withAnimation {
            scrollProxy?.scrollTo(currentIndex, anchor: .center)
        }
    }
}

// MARK: - Edit Queue Item Row

/// Queue item row for edit mode with drag handle and remove button
struct EditQueueItemRow: View {
    let item: QueueItem
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            // Album art
            if !item.albumArtURL.isEmpty, let url = URL(string: item.albumArtURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 40, height: 40)
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .cornerRadius(4)
                    case .failure:
                        albumArtPlaceholder
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                albumArtPlaceholder
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.trackName)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(item.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(item.durationFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Delete button
            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var albumArtPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.caption)
            .frame(width: 40, height: 40)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(4)
    }
}

// MARK: - Queue Drop Delegate

/// Drop delegate for reordering queue items in edit mode
struct QueueDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedIndex: Int?
    let onMove: (Int, Int) -> Void

    func performDrop(info _: DropInfo) -> Bool {
        if let from = draggedIndex, from != targetIndex {
            onMove(from, targetIndex)
        }
        draggedIndex = nil
        return true
    }

    func dropEntered(info _: DropInfo) {
        // Visual feedback is handled by the opacity modifier on the row
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        // Keep draggedIndex until performDrop
    }
}
