//
//  QueueListView.swift
//  Spotifly
//
//  Displays current playback queue
//

import SwiftUI

struct QueueListView: View {
    let authResult: SpotifyAuthResult
    @Bindable var queueViewModel: QueueViewModel
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            if let error = queueViewModel.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Failed to load queue")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
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
                    Text("Queue is empty")
                        .font(.headline)
                    Text("Play a track, album, playlist, or artist to see the queue")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(queueViewModel.queueItems.enumerated()), id: \.element.id) { index, item in
                            TrackRow(
                                track: item.toTrackRowData(),
                                index: index,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                currentIndex: playbackViewModel.currentIndex,
                                playbackViewModel: playbackViewModel,
                            ) {
                                do {
                                    try SpotifyPlayer.jumpToIndex(index)
                                    playbackViewModel.updateQueueState()
                                } catch {
                                    playbackViewModel.errorMessage = error.localizedDescription
                                }
                            }

                            if index < queueViewModel.queueItems.count - 1 {
                                Divider()
                                    .padding(.leading, 78)
                            }
                        }
                    }
                }
                .refreshable {
                    queueViewModel.refresh()
                }
            }
        }
        .task {
            queueViewModel.loadQueue()
        }
    }
}
