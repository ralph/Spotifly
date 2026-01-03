//
//  TrackRow.swift
//  Spotifly
//
//  Reusable track row component for displaying tracks across different views
//

import SwiftUI

/// Data needed to display a track row
struct TrackRowData: Identifiable {
    let id: String
    let uri: String
    let name: String
    let artistName: String
    let albumArtURL: String?
    let durationMs: Int
    let trackNumber: Int? // Optional - only shown in album views

    var durationFormatted: String {
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Reusable track row view
struct TrackRow: View {
    let track: TrackRowData
    let showTrackNumber: Bool // Show track number instead of index
    let index: Int? // Optional index for queue
    let isCurrentTrack: Bool
    let isPlayedTrack: Bool // For queue - tracks that have already played
    @Bindable var playbackViewModel: PlaybackViewModel
    let onDoubleTap: () -> Void

    init(
        track: TrackRowData,
        showTrackNumber: Bool = false,
        index: Int? = nil,
        currentlyPlayingURI: String?,
        currentIndex: Int? = nil,
        playbackViewModel: PlaybackViewModel,
        onDoubleTap: @escaping () -> Void,
    ) {
        self.track = track
        self.showTrackNumber = showTrackNumber
        self.index = index
        isCurrentTrack = currentlyPlayingURI == track.uri
        isPlayedTrack = if let index, let currentIndex {
            index < currentIndex
        } else {
            false
        }
        self.playbackViewModel = playbackViewModel
        self.onDoubleTap = onDoubleTap
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number, index, or now playing indicator
            ZStack {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .symbolEffect(.variableColor.iterative, isActive: playbackViewModel.isPlaying)
                } else if showTrackNumber, let trackNumber = track.trackNumber {
                    Text("\(trackNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let index {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // No number shown
                    EmptyView()
                }
            }
            .frame(width: 30, alignment: showTrackNumber ? .trailing : .center)

            // Album art (if available)
            if let albumArtURL = track.albumArtURL, !albumArtURL.isEmpty, let url = URL(string: albumArtURL) {
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
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline)
                    .fontWeight(isCurrentTrack ? .semibold : .regular)
                    .foregroundStyle(isCurrentTrack ? .green : .primary)
                    .lineLimit(1)

                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(track.durationFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Context menu
            Menu {
                Button {
                    // TODO: Add to queue
                } label: {
                    Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    // TODO: Start song radio
                } label: {
                    Label("Start Song Radio", systemImage: "antenna.radiowaves.left.and.right")
                }

                Divider()

                Button {
                    // TODO: Go to artist
                } label: {
                    Label("Go to Artist", systemImage: "person.circle")
                }

                Button {
                    // TODO: Go to album
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }

                Divider()

                Button {
                    // TODO: Copy to clipboard
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isCurrentTrack ? Color.green.opacity(0.1) : Color.clear)
        .opacity(isPlayedTrack ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTap()
        }
    }
}

// MARK: - Conversions from different track types

extension QueueItem {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: uri,
            uri: uri,
            name: trackName,
            artistName: artistName,
            albumArtURL: albumArtURL,
            durationMs: Int(durationMs),
            trackNumber: nil,
        )
    }
}

extension AlbumTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: nil, // Album tracks don't have individual art
            durationMs: durationMs,
            trackNumber: trackNumber,
        )
    }
}

extension PlaylistTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: nil,
        )
    }
}

extension SearchTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: nil,
        )
    }
}
