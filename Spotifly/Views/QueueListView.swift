//
//  QueueListView.swift
//  Spotifly
//
//  Displays current playback queue
//

import SwiftUI

struct QueueListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(QueueService.self) private var queueService
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            if let error = store.queueErrorMessage {
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
            } else if store.queueItems.isEmpty {
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
            } else {
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
                                accessToken: session.accessToken,
                                doubleTapBehavior: .jumpToQueueIndex,
                            )

                            if index < store.queueItems.count - 1 {
                                Divider()
                                    .padding(.leading, 78)
                            }
                        }
                    }
                }
                .refreshable {
                    queueService.refresh()
                    await queueService.loadFavorites(accessToken: session.accessToken)
                }
            }
        }
        .task {
            queueService.loadQueue()
            await queueService.loadFavorites(accessToken: session.accessToken)
        }
    }
}
