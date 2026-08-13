//
//  PathfinderSearch.swift
//  Spotifly
//
//  What the four search operations send back.
//

import Foundation

// MARK: - Envelope

/// `{ "data": { "searchV2": { "<kind>": { "items": [...], "totalCount": n } } } }`
///
/// Every search operation nests its results the same way, differing only in the key under
/// `searchV2` — which is why the kind-specific payloads below exist rather than one type with
/// four optional fields.
nonisolated struct PathfinderResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    struct SearchV2: Decodable, Sendable {
        let searchV2: Payload?
    }

    let data: SearchV2?

    var results: Payload? {
        data?.searchV2
    }
}

/// A page of results. `items[].item.data` is the entity; the two wrappers carry match metadata
/// this app does not use.
nonisolated struct PathfinderItems<Item: Decodable & Sendable>: Decodable, Sendable {
    struct Matched: Decodable, Sendable {
        struct Wrapper: Decodable, Sendable {
            let data: Item?
        }

        let item: Wrapper?
    }

    let items: [Matched]?
    let totalCount: Int?

    /// The entities, with anything unreadable dropped rather than failing the whole page.
    var entities: [Item] {
        (items ?? []).compactMap(\.item?.data)
    }
}

// MARK: - Per-kind payloads

nonisolated struct PathfinderTrackResults: Decodable, Sendable {
    let tracksV2: PathfinderItems<PathfinderTrack>?
}

nonisolated struct PathfinderAlbumResults: Decodable, Sendable {
    let albumsV2: PathfinderItems<PathfinderAlbum>?
}

nonisolated struct PathfinderArtistResults: Decodable, Sendable {
    let artists: PathfinderItems<PathfinderArtist>?
}

nonisolated struct PathfinderPlaylistResults: Decodable, Sendable {
    let playlists: PathfinderItems<PathfinderPlaylist>?
}

// MARK: - Entities

/// An image, in the shape pathfinder returns everywhere: a list of sources, largest first.
nonisolated struct PathfinderImage: Decodable, Sendable {
    struct Source: Decodable, Sendable {
        let url: String?
        let width: Int?
        let height: Int?
    }

    let sources: [Source]?

    /// The widest source, which is what the app shows.
    var largestURL: String? {
        (sources ?? []).max { ($0.width ?? 0) < ($1.width ?? 0) }?.url
    }
}

nonisolated struct PathfinderArtistSnippet: Decodable, Sendable {
    struct Profile: Decodable, Sendable {
        let name: String?
    }

    let uri: String?
    let profile: Profile?

    var name: String? {
        profile?.name
    }

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }
}

nonisolated struct PathfinderArtistList: Decodable, Sendable {
    let items: [PathfinderArtistSnippet]?
}

nonisolated struct PathfinderTrack: Decodable, Sendable {
    struct AlbumOfTrack: Decodable, Sendable {
        let id: String?
        let uri: String?
        let name: String?
        let coverArt: PathfinderImage?
    }

    struct Duration: Decodable, Sendable {
        let totalMilliseconds: Int?
    }

    struct Playability: Decodable, Sendable {
        let playable: Bool?
    }

    let id: String?
    let uri: String?
    let name: String?
    let albumOfTrack: AlbumOfTrack?
    let artists: PathfinderArtistList?
    let duration: Duration?
    let playability: Playability?

    var durationMs: Int? {
        duration?.totalMilliseconds
    }

    var artistNames: [String] {
        (artists?.items ?? []).compactMap(\.name)
    }
}

nonisolated struct PathfinderAlbum: Decodable, Sendable {
    struct ReleaseDate: Decodable, Sendable {
        let year: Int?
    }

    /// Search results carry no `id` — only the URI — so it is derived. `AppStore` keys albums
    /// by id, so this is not cosmetic.
    let uri: String?
    let name: String?
    let type: String?
    let artists: PathfinderArtistList?
    let coverArt: PathfinderImage?
    let date: ReleaseDate?

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }

    var artistNames: [String] {
        (artists?.items ?? []).compactMap(\.name)
    }
}

nonisolated struct PathfinderArtist: Decodable, Sendable {
    struct Visuals: Decodable, Sendable {
        let avatarImage: PathfinderImage?
    }

    let uri: String?
    let profile: PathfinderArtistSnippet.Profile?
    let visuals: Visuals?

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }

    var name: String? {
        profile?.name
    }

    var imageURL: String? {
        visuals?.avatarImage?.largestURL
    }
}

nonisolated struct PathfinderPlaylist: Decodable, Sendable {
    struct Owner: Decodable, Sendable {
        struct Data: Decodable, Sendable {
            let name: String?
            let username: String?
        }

        let data: Data?
    }

    struct Images: Decodable, Sendable {
        let items: [PathfinderImage]?
    }

    let uri: String?
    let name: String?
    let description: String?
    let images: Images?
    let ownerV2: Owner?

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }

    var ownerName: String? {
        ownerV2?.data?.name ?? ownerV2?.data?.username
    }

    var imageURL: String? {
        (images?.items ?? []).first?.largestURL
    }
}

// MARK: - URIs

/// `spotify:track:6rqhFgbbKwnb9MLmUQDhG6` -> `6rqhFgbbKwnb9MLmUQDhG6`.
///
/// Pathfinder identifies most entities by URI alone, while `AppStore` keys them by id, so the
/// two have to be bridged somewhere. Here, once.
nonisolated enum SpotifyURI {
    static func id(from uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count >= 3, parts[0] == "spotify", let last = parts.last, !last.isEmpty else {
            return nil
        }
        return String(last)
    }
}
