//
//  PathfinderPlaylist.swift
//  Spotifly
//
//  What `fetchPlaylist` sends back, and what the playlist mutations answer with.
//

import Foundation

/// `{ "data": { "playlistV2": { … } } }`
nonisolated struct PathfinderPlaylistResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let playlistV2: PathfinderPlaylistUnion?
    }

    let data: Payload?
}

/// A playlist and its contents.
///
/// **Three operation names share one hash** — `fetchPlaylist`, `fetchPlaylistContents` and
/// `fetchPlaylistMetadata` all resolve to the same stored document, and `operationName` selects
/// between them. Measured on 2026-08-13 against a one-track playlist: metadata answered in 3062
/// bytes with tracks reduced to a uri and a duration, contents in 4396 with no playlist fields
/// at all, and `fetchPlaylist` in 7144 with both. The app wants both, so it asks for both.
nonisolated struct PathfinderPlaylistUnion: Decodable, Sendable {
    struct Owner: Decodable, Sendable {
        struct Data: Decodable, Sendable {
            let username: String?
            let name: String?
            let uri: String?
        }

        let data: Data?
    }

    struct Images: Decodable, Sendable {
        let items: [PathfinderImage]?
    }

    struct Content: Decodable, Sendable {
        let items: [PathfinderPlaylistItem]?
        let totalCount: Int?
    }

    let uri: String?
    let name: String?
    let description: String?
    let ownerV2: Owner?
    let images: Images?
    let content: Content?

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }
}

/// One entry in a playlist.
///
/// **`uid` is the important field.** It identifies *this occurrence* of a track, and it is what
/// `removeFromPlaylist` and `moveItemsInPlaylist` operate on — neither takes a track uri. A
/// playlist can hold the same song twice, and only a uid tells the two apart.
///
/// The track is nested under `itemV2.data`, which is a fourth distinct item shape from this API:
/// search uses `item.data`, the album view uses `track`, an artist's discography uses
/// `releases.items`, and playlists use this.
nonisolated struct PathfinderPlaylistItem: Decodable, Sendable {
    struct AddedAt: Decodable, Sendable {
        let isoString: String?
    }

    struct ItemV2: Decodable, Sendable {
        let data: PathfinderPlaylistTrack?
    }

    let uid: String?
    let addedAt: AddedAt?
    let itemV2: ItemV2?

    var track: PathfinderPlaylistTrack? {
        itemV2?.data
    }
}

/// A track as a playlist lists it.
nonisolated struct PathfinderPlaylistTrack: Decodable, Sendable {
    struct Duration: Decodable, Sendable {
        let totalMilliseconds: Int?
    }

    struct AlbumOfTrack: Decodable, Sendable {
        let uri: String?
        let name: String?
        let coverArt: PathfinderImage?
    }

    struct ArtistList: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            struct Profile: Decodable, Sendable {
                let name: String?
            }

            let uri: String?
            let profile: Profile?
        }

        let items: [Item]?
    }

    let uri: String?
    let name: String?
    let trackNumber: Int?
    let discNumber: Int?
    let trackDuration: Duration?
    let albumOfTrack: AlbumOfTrack?
    let artists: ArtistList?

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }

    var artistNames: [String] {
        (artists?.items ?? []).compactMap { $0.profile?.name }
    }

    var firstArtistId: String? {
        (artists?.items ?? []).first?.uri.flatMap(SpotifyURI.id(from:))
    }

    var albumId: String? {
        albumOfTrack?.uri.flatMap(SpotifyURI.id(from:))
    }
}

// MARK: - Mutations

/// What a playlist mutation answers with.
///
/// **The status code does not report success.** A rejected mutation comes back as HTTP 200 with
/// a `__typename` naming the failure — `{"addItemsToPlaylist":{"__typename":"NotFound"}}` for a
/// playlist that does not exist. A client checking only the status would record the write as
/// having happened and never roll back its optimistic update.
///
/// So success is recognised by name, and anything else is a failure. Measured on 2026-08-13:
/// `AddItemsToPlaylistPayload` and `RemoveItemsFromPlaylistPayload` on success.
nonisolated struct PathfinderMutationResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        let __typename: String?
        let message: String?
    }

    struct Payload: Decodable, Sendable {
        let addItemsToPlaylist: Result?
        let removeItemsFromPlaylist: Result?
        let moveItemsInPlaylist: Result?

        var result: Result? {
            addItemsToPlaylist ?? removeItemsFromPlaylist ?? moveItemsInPlaylist
        }
    }

    let data: Payload?

    /// The names Spotify returns when the write actually happened.
    private static let successTypes: Set<String> = [
        "AddItemsToPlaylistPayload",
        "RemoveItemsFromPlaylistPayload",
        "MoveItemsInPlaylistPayload",
    ]

    /// Nil when the mutation succeeded, otherwise what went wrong.
    var failure: String? {
        guard let result = data?.result, let typename = result.__typename else {
            return "the response named no result"
        }
        guard !Self.successTypes.contains(typename) else { return nil }

        return result.message.map { "\(typename): \($0)" } ?? typename
    }
}

/// Where an added or moved item lands.
///
/// `fromUid` is only read for `beforeUid`/`afterUid`; the service rejects those two without it,
/// which is how the enum's members were established.
nonisolated struct PlaylistItemPosition: Encodable, Sendable {
    enum MoveType: String, Encodable, Sendable {
        case bottom = "BOTTOM_OF_PLAYLIST"
        case top = "TOP_OF_PLAYLIST"
        case beforeUid = "BEFORE_UID"
        case afterUid = "AFTER_UID"
    }

    var moveType: MoveType
    var fromUid: String?

    static let bottom = PlaylistItemPosition(moveType: .bottom)

    static func before(uid: String) -> PlaylistItemPosition {
        PlaylistItemPosition(moveType: .beforeUid, fromUid: uid)
    }

    static func after(uid: String) -> PlaylistItemPosition {
        PlaylistItemPosition(moveType: .afterUid, fromUid: uid)
    }
}

/// The variables `fetchPlaylist` takes.
///
/// `enableWatchFeedEntrypoint` is required, not optional decoration: the stored query
/// references it, and omitting it is a 400 rather than a default. Leaving it out is exactly
/// what broke the playlist page on the first run of this migration.
nonisolated struct PathfinderPlaylistVariables: Encodable, Sendable {
    var uri: String
    var offset: Int = 0
    var limit: Int = 300
    var enableWatchFeedEntrypoint: Bool = false
}

nonisolated struct PathfinderAddVariables: Encodable, Sendable {
    var playlistUri: String
    var playlistItemUris: [String]
    var newPosition: PlaylistItemPosition
}

nonisolated struct PathfinderRemoveVariables: Encodable, Sendable {
    var playlistUri: String
    var uids: [String]
}

nonisolated struct PathfinderMoveVariables: Encodable, Sendable {
    var playlistUri: String
    var uids: [String]
    var newPosition: PlaylistItemPosition
}
