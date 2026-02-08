//
//  TrackCard.swift
//  Spotifly
//
//  Reusable track card for horizontal scroll sections
//

import SwiftUI

struct TrackCard: View {
    let track: Track
    @Bindable var playbackViewModel: PlaybackViewModel
    var currentSection: NavigationItem = .searchResults

    @Environment(SpotifySession.self) private var session

    var body: some View {
        Button {
            playTrack()
        } label: {
            VStack(spacing: 8) {
                if let imageURL = track.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .cornerRadius(4)
                                .shadow(radius: 2)
                        case .failure:
                            trackPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    trackPlaceholder
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            TrackContextMenu(
                track: track,
                currentSection: currentSection,
                selectionId: nil,
                playbackViewModel: playbackViewModel,
            )
        }
    }

    private var trackPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }

    private func playTrack() {
        Task {
            // Ensure player is initialized before starting radio
            let token = await session.validAccessToken()
            await playbackViewModel.initializeIfNeeded(accessToken: token)
            SpotifyPlayer.playRadio(trackUri: track.uri)
        }
    }
}
