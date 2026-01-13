//
//  QueueListView.swift
//  Spotifly
//
//  Displays current playback queue (real-time updates via Spirc/Mercury)
//

import SwiftUI

struct QueueListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(QueueService.self) private var queueService
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var scrollProxy: ScrollViewProxy?

    /// Currently playing index from store
    private var currentIndex: Int {
        store.currentIndex
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
            } else {
                normalModeContent
            }
        }
        .task {
            // Load favorites for queue items (queue itself auto-updates via Spirc subscription)
            let token = await session.validAccessToken()
            await queueService.loadFavorites(accessToken: token)
        }
        .onChange(of: store.queueItems) { _, _ in
            // When queue updates, refresh favorites for new items
            Task {
                let token = await session.validAccessToken()
                await queueService.loadFavorites(accessToken: token)
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
            .disabled(store.queueItems.isEmpty)
            .help("queue.scroll_to_current")
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
                            currentIndex: currentIndex,
                            playbackViewModel: playbackViewModel,
                            doubleTapBehavior: .playTrack,
                            currentSection: .queue,
                        )
                        .id(index)

                        if index < store.queueItems.count - 1 {
                            Divider()
                                .padding(.leading, 78)
                        }
                    }
                }
            }
            .onAppear { scrollProxy = proxy }
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

    // MARK: - Navigation

    private func scrollToCurrentTrack() {
        guard currentIndex < store.queueItems.count else { return }
        withAnimation {
            scrollProxy?.scrollTo(currentIndex, anchor: .center)
        }
    }
}
