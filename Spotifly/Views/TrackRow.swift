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
    let albumId: String? // For navigation to album
    let artistId: String? // For navigation to artist
    let externalUrl: String? // Web URL for sharing

    var durationFormatted: String {
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Double-tap behavior for TrackRow
enum TrackRowDoubleTapBehavior {
    case playTrack // Play just this track
    case jumpToQueueIndex // Jump to this index in the queue (for QueueListView)
}

/// Reusable track row view
struct TrackRow: View {
    let track: TrackRowData
    let showTrackNumber: Bool // Show track number instead of index
    let index: Int? // Optional index for queue
    let isCurrentTrack: Bool
    let isPlayedTrack: Bool // For queue - tracks that have already played
    @Bindable var playbackViewModel: PlaybackViewModel
    let accessToken: String? // For playback and queue operations
    let doubleTapBehavior: TrackRowDoubleTapBehavior

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var isFavorited = false
    @State private var isCheckingFavorite = false

    init(
        track: TrackRowData,
        showTrackNumber: Bool = false,
        index: Int? = nil,
        currentlyPlayingURI: String?,
        currentIndex: Int? = nil,
        playbackViewModel: PlaybackViewModel,
        accessToken: String? = nil,
        doubleTapBehavior: TrackRowDoubleTapBehavior = .playTrack,
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
        self.accessToken = accessToken
        self.doubleTapBehavior = doubleTapBehavior
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

            // Heart button (favorite status)
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.caption)
                    .foregroundStyle(isFavorited ? .red : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCheckingFavorite || accessToken == nil)
            .opacity(isCheckingFavorite ? 0.5 : 1.0)

            // Context menu
            Menu {
                Button {
                    playNext()
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(accessToken == nil)

                Button {
                    addToQueue()
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                .disabled(accessToken == nil)

                Button {
                    startSongRadio()
                } label: {
                    Label("Start Song Radio", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(accessToken == nil)

                Divider()

                Button {
                    if let artistId = track.artistId, let accessToken {
                        navigationCoordinator.navigateToArtist(
                            artistId: artistId,
                            accessToken: accessToken,
                        )
                    }
                } label: {
                    Label("Go to Artist", systemImage: "person.circle")
                }
                .disabled(track.artistId == nil || accessToken == nil)

                Button {
                    if let albumId = track.albumId, let accessToken {
                        navigationCoordinator.navigateToAlbum(
                            albumId: albumId,
                            accessToken: accessToken,
                        )
                    }
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
                .disabled(track.albumId == nil || accessToken == nil)

                Divider()

                Button {
                    copyToClipboard()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(track.externalUrl == nil)
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
            handleDoubleTap()
        }
        .task {
            await checkFavoriteStatus()
        }
    }

    private func copyToClipboard() {
        guard let externalUrl = track.externalUrl else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(externalUrl, forType: .string)
    }

    private func handleDoubleTap() {
        guard let accessToken else { return }

        switch doubleTapBehavior {
        case .playTrack:
            Task {
                await playbackViewModel.play(
                    uriOrUrl: track.uri,
                    accessToken: accessToken,
                )
            }
        case .jumpToQueueIndex:
            guard let index else { return }
            do {
                try SpotifyPlayer.jumpToIndex(index)
                playbackViewModel.updateQueueState()
            } catch {
                playbackViewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func playNext() {
        guard let accessToken else { return }

        Task {
            await playbackViewModel.playNext(
                trackUri: track.uri,
                accessToken: accessToken,
            )
        }
    }

    private func addToQueue() {
        guard let accessToken else { return }

        Task {
            await playbackViewModel.addToQueue(
                trackUri: track.uri,
                accessToken: accessToken,
            )
        }
    }

    private func startSongRadio() {
        guard let accessToken else { return }

        Task {
            do {
                // Ensure player is initialized (needed for radio API)
                await playbackViewModel.initializeIfNeeded(accessToken: accessToken)

                // Use librespot's internal radio API
                let radioTrackUris = try SpotifyPlayer.getRadioTracks(trackUri: track.uri)

                if !radioTrackUris.isEmpty {
                    // Filter out the base track if it's already in the radio results
                    let filteredRadioUris = radioTrackUris.filter { $0 != track.uri }

                    // Play the current track followed by radio tracks
                    var trackUris = [track.uri]
                    trackUris.append(contentsOf: filteredRadioUris)

                    await playbackViewModel.playTracks(
                        trackUris,
                        accessToken: accessToken,
                    )

                    // Navigate to queue to show radio tracks
                    navigationCoordinator.navigateToQueue()
                } else {
                    playbackViewModel.errorMessage = "No radio tracks found"
                }
            } catch {
                playbackViewModel.errorMessage = "Failed to start radio: \(error.localizedDescription)"
            }
        }
    }

    private func toggleFavorite() {
        guard let accessToken else { return }

        Task {
            isCheckingFavorite = true

            do {
                if isFavorited {
                    try await SpotifyAPI.removeSavedTrack(
                        accessToken: accessToken,
                        trackId: track.id,
                    )
                    isFavorited = false
                } else {
                    try await SpotifyAPI.saveTrack(
                        accessToken: accessToken,
                        trackId: track.id,
                    )
                    isFavorited = true
                }
            } catch {
                // Silently fail - revert state
            }

            isCheckingFavorite = false
        }
    }

    private func checkFavoriteStatus() async {
        guard let accessToken else { return }

        isCheckingFavorite = true

        do {
            isFavorited = try await SpotifyAPI.checkSavedTrack(
                accessToken: accessToken,
                trackId: track.id,
            )
        } catch {
            // Silently fail - just leave as unfavorited
            isFavorited = false
        }

        isCheckingFavorite = false
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
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl
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
            albumId: nil, // Not needed - already viewing the album
            artistId: artistId,
            externalUrl: externalUrl,
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
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
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
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}

extension SavedTrack {
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: nil,
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}
