//
//  NowPlayingInspector.swift
//  Spotifly
//
//  "Now Playing": the playing track large, and what comes next
//

import SwiftUI

/// The window's inspector: the playing track's cover, title, artist and album, and the next eight
/// tracks of the queue, each of which plays on a click.
struct NowPlayingInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(PlayerModel.self) private var player
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    /// How many of the next tracks it lists.
    private static let upNextLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("inspector.title")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 52)

            if let track = playbackViewModel.currentTrack {
                nowPlaying(track)

                Divider()

                upNext
            } else {
                ContentUnavailableView("inspector.nothing_playing", systemImage: "music.note")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Opaque, as the handoff draws it: the glass let the page's covers bleed through.
        .background(.background)
    }

    private func nowPlaying(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Artwork(
                images: track.images,
                size: 280,
                shape: AnyShape(.rect(cornerRadius: 10)),
                symbol: "music.note",
                symbolFont: .system(size: 60),
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.title2.bold())
                Text(track.artistName)
                    .foregroundStyle(.secondary)
                if let albumName = track.albumName {
                    Text(albumName)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    /// The next tracks the store has metadata for, at most eight.
    private var upNextRows: ArraySlice<(entry: QueueEntry, track: Track, row: PlaybackViewModel.QueueRow)> {
        player.queueEntries.nextRows(in: store.tracks).prefix(Self.upNextLimit)
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("inspector.up_next")
                    .font(.headline)
                Spacer()
                Text(localizedNumberString("metadata.tracks", player.queueEntries.nextTracks.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                VStack(spacing: 2) {
                    // By the row's uid, which stays with it as the queue advances, so the rows
                    // that remain keep their covers; by position where there is none, as a track
                    // can be queued twice.
                    ForEach(upNextRows.enumerated().map { (id: $0.element.entry.uid ?? String($0.offset), next: $0.element) }, id: \.id) { item in
                        let next = item.next
                        Button {
                            // One Spotify will not play starts nothing, as in `TrackRow`: the skip
                            // would step over it and interrupt what plays for a later track.
                            if let message = next.track.unplayableMessage {
                                playbackViewModel.errorMessage = message
                            } else {
                                playbackViewModel.play(queueRow: next.row)
                            }
                        } label: {
                            UpNextRow(track: next.track)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// One of the next tracks: the cover, title over artist, and the duration.
private struct UpNextRow: View {
    let track: Track

    /// Built once rather than on every redraw, as `TrackRow`'s is.
    private static let artworkShape = AnyShape(.rect(cornerRadius: 4))

    var body: some View {
        HStack(spacing: 10) {
            Artwork(
                images: track.images,
                size: 32,
                shape: Self.artworkShape,
                symbol: "music.note",
                symbolFont: .caption,
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.durationFormatted)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(.rect)
        // Dimmed, with the reason, as in every other list.
        .opacity(track.isPlayable ? 1 : 0.5)
        .help(ifAny: track.unplayableMessage)
    }
}
