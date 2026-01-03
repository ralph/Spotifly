//
//  QueueListView.swift
//  Spotifly
//
//  Displays current playback queue
//

import SwiftUI

struct QueueListView: View {
    @Environment(SpotifySession.self) private var session
    @Bindable var queueViewModel: QueueViewModel
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            if let error = queueViewModel.errorMessage {
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
                        queueViewModel.loadQueue()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if queueViewModel.queueItems.isEmpty {
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
                        ForEach(Array(queueViewModel.queueItems.enumerated()), id: \.offset) { index, item in
                            let trackData = item.toTrackRowData()
                            TrackRow(
                                track: trackData,
                                index: index,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                currentIndex: playbackViewModel.currentIndex,
                                playbackViewModel: playbackViewModel,
                                accessToken: session.accessToken,
                                doubleTapBehavior: .jumpToQueueIndex,
                                initialFavorited: queueViewModel.isFavorited(trackId: trackData.trackId),
                                onFavoriteChanged: { newValue in
                                    queueViewModel.setFavorited(trackId: trackData.trackId, value: newValue)
                                },
                            )

                            if index < queueViewModel.queueItems.count - 1 {
                                Divider()
                                    .padding(.leading, 78)
                            }
                        }
                    }
                }
                .refreshable {
                    queueViewModel.refresh()
                    await queueViewModel.loadFavorites(accessToken: session.accessToken)
                }
            }
        }
        .task {
            queueViewModel.loadQueue()
            await queueViewModel.loadFavorites(accessToken: session.accessToken)
        }
    }
}
