//
//  ArtistCard.swift
//  Spotifly
//
//  Reusable circular artist card for horizontal scroll sections
//

import SwiftUI

struct ArtistCard: View {
    let id: String
    let name: String
    let imageURL: URL?

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            navigationCoordinator.navigateToArtist(artistId: id)
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
                                .clipShape(Circle())
                                .shadow(radius: 2)
                        case .failure:
                            artistPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    artistPlaceholder
                }

                Text(name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 120)
            }
        }
        .buttonStyle(.plain)
    }

    private var artistPlaceholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary),
            )
    }
}

// MARK: - Convenience initializers

extension ArtistCard {
    /// Initialize from an Artist entity
    init(artist: Artist) {
        id = artist.id
        name = artist.name
        imageURL = artist.imageURL
    }
}
