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
                            QueueItemRow(
                                item: item,
                                index: index,
                                isCurrentTrack: index == queueViewModel.currentIndex,
                                playbackViewModel: playbackViewModel,
                                accessToken: authResult.accessToken,
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
                }
            }
        }
        .task {
            queueViewModel.loadQueue()
        }
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let index: Int
    let isCurrentTrack: Bool
    @Bindable var playbackViewModel: PlaybackViewModel
    let accessToken: String

    var body: some View {
        HStack(spacing: 12) {
            // Track number or now playing indicator
            ZStack {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .symbolEffect(.variableColor.iterative, isActive: playbackViewModel.isPlaying)
                } else {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, alignment: .center)

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
                        Image(systemName: "music.note")
                            .font(.caption)
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.caption)
                    .frame(width: 40, height: 40)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.trackName)
                    .font(.subheadline)
                    .fontWeight(isCurrentTrack ? .semibold : .regular)
                    .foregroundStyle(isCurrentTrack ? .green : .primary)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isCurrentTrack ? Color.green.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // TODO: Jump to track in queue
        }
    }
}
