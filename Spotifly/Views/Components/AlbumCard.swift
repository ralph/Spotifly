//
//  AlbumCard.swift
//  Spotifly
//
//  Reusable album card for horizontal scroll sections
//

import SwiftUI

struct AlbumCard: View {
    let id: String
    let name: String
    let artistName: String
    let imageURL: URL?

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            navigationCoordinator.navigateToAlbum(albumId: id)
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
                            albumPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    albumPlaceholder
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var albumPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }
}

// MARK: - Convenience initializers

extension AlbumCard {
    /// Initialize from an Album entity
    init(album: Album) {
        id = album.id
        name = album.name
        artistName = album.artistName
        imageURL = album.imageURL
    }
}
