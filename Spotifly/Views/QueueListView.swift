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
    @State private var isRefreshing = false

    /// Flattened queue: previous + current + next
    private var allTracks: [Track] {
        var tracks = store.previousTracks
        if let current = store.currentTrack {
            tracks.append(current)
        }
        tracks.append(contentsOf: store.nextTracks)
        return tracks
    }

    /// Currently playing index (position after previous tracks)
    private var currentIndex: Int {
        store.currentIndex
    }

    /// Total song count for header
    private var totalSongCount: Int {
        store.queueLength
    }

    /// Unplayed song count for header (next tracks only)
    private var unplayedSongCount: Int {
        store.nextTracks.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header
            queueHeader

            Divider()

            // Scrollable content
            if let error = store.queueErrorMessage {
                errorView(error)
            } else if allTracks.isEmpty {
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
        .onChange(of: store.currentTrackURI) { _, _ in
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

            // Refresh button
            Button {
                refreshQueue()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .help("queue.refresh")

            // Scroll to current button
            Button {
                scrollToCurrentTrack()
            } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .buttonStyle(.bordered)
            .disabled(allTracks.isEmpty)
            .help("queue.scroll_to_current")
        }
        .padding()
        .background(.regularMaterial)
    }

    private func refreshQueue() {
        isRefreshing = true
        Task {
            await SpotifyPlayer.refreshQueue()
            isRefreshing = false
        }
    }

    // MARK: - Normal Mode Content

    private var normalModeContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(allTracks.enumerated()), id: \.offset) { index, track in
                        let trackData = track.toTrackRowData()
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

                        if index < allTracks.count - 1 {
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
        guard currentIndex < allTracks.count else { return }
        withAnimation {
            scrollProxy?.scrollTo(currentIndex, anchor: .center)
        }
    }
}
