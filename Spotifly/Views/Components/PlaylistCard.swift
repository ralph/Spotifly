//
//  PlaylistCard.swift
//  Spotifly
//
//  Reusable playlist card for horizontal scroll sections
//

import SwiftUI

struct PlaylistCard: View {
    let id: String
    let name: String
    let imageURL: URL?

    /// The playlist object needed for navigation (contains full data)
    private let searchPlaylist: SearchPlaylist?

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            if let searchPlaylist {
                navigationCoordinator.navigateToPlaylist(searchPlaylist)
            }
        } label: {
            VStack(spacing: 8) {
                if let imageURL {
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
                            playlistPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    playlistPlaceholder
                }

                Text(name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var playlistPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }
}

// MARK: - Convenience initializers

extension PlaylistCard {
    /// Initialize from a Playlist entity
    init(playlist: Playlist) {
        id = playlist.id
        name = playlist.name
        imageURL = playlist.imageURL
        searchPlaylist = SearchPlaylist(from: playlist)
    }

    /// Initialize from a SearchPlaylist
    init(playlist: SearchPlaylist) {
        id = playlist.id
        name = playlist.name
        imageURL = playlist.imageURL
        searchPlaylist = playlist
    }
}
