//
//  PathfinderLibrary.swift
//  Spotifly
//
//  What the library operations send back.
//

import Foundation

// MARK: - libraryV3

/// `{ "data": { "me": { "libraryV3": { … } } } }`
///
/// One query answers what the Web API spread across `/me/playlists`, `/me/albums` and
/// `/me/following?type=artist`: the same document returns whichever kinds `filters` names, and
/// the app asks for one kind at a time because its three library sections are separate screens.
nonisolated struct PathfinderLibraryResponse<Entity: Decodable & Sendable>: Decodable, Sendable {
    struct Me: Decodable, Sendable {
        let libraryV3: PathfinderLibraryPage<Entity>?
    }

    struct Payload: Decodable, Sendable {
        let me: Me?
    }

    let data: Payload?

    var page: PathfinderLibraryPage<Entity>? {
        data?.me?.libraryV3
    }
}

/// A page of library entries.
///
/// **`totalCount` can exceed what the page renders**, so it is what Spotify holds rather than
/// what the list will show — the same mismatch the saved-tracks list lives with, where relinking
/// makes several saved entries resolve to one track. Pagination therefore advances by the item
/// count, never by how many entities survived.
nonisolated struct PathfinderLibraryPage<Entity: Decodable & Sendable>: Decodable, Sendable {
    let totalCount: Int?
    let items: [PathfinderLibraryItem<Entity>]?

    /// The entities, with anything unreadable dropped rather than failing the whole page.
    ///
    /// **Decoding is not a filter.** A playlist *folder* decodes as a `PathfinderPlaylist`
    /// perfectly well — it carries a `uri` and a `name` — so nothing here rejects it, and the
    /// kinds the app cannot show are excluded by not asking for them (`flatten`, and no
    /// `Audiobooks` filter) and by the kind check in `PathfinderPlaylist.id`.
    var entities: [Entity] {
        (items ?? []).compactMap(\.item?.data)
    }
}

/// One library entry: when it was added, and the thing that was added.
///
/// The uri sits on the wrapper as `_uri` *beside* the entity rather than inside it, which is why
/// this type exists at all instead of the page holding entities directly. The entity does carry
/// its own `uri` for the three kinds the app stores, so the wrapper's copy is not read — but it
/// is the shape to remember, because `fetchLibraryTracks` below has only the wrapper's.
nonisolated struct PathfinderLibraryItem<Entity: Decodable & Sendable>: Decodable, Sendable {
    struct Wrapper: Decodable, Sendable {
        let data: Entity?
    }

    let addedAt: PathfinderTimestamp?
    let pinned: Bool?
    let item: Wrapper?
}

/// `{ "isoString": "2026-08-13T07:12:40Z" }`, which is how this API spells every timestamp.
nonisolated struct PathfinderTimestamp: Decodable, Sendable {
    let isoString: String?
}

// MARK: - fetchLibraryTracks

/// `{ "data": { "me": { "library": { "tracks": { … } } } } }`
///
/// Saved tracks are *not* part of `libraryV3` — they have their own operation and their own
/// nesting, one level deeper than the rest of the library.
nonisolated struct PathfinderLibraryTracksResponse: Decodable, Sendable {
    struct Library: Decodable, Sendable {
        let tracks: PathfinderLibraryTrackPage?
    }

    struct Me: Decodable, Sendable {
        let library: Library?
    }

    struct Payload: Decodable, Sendable {
        let me: Me?
    }

    let data: Payload?

    var page: PathfinderLibraryTrackPage? {
        data?.me?.library?.tracks
    }
}

nonisolated struct PathfinderLibraryTrackPage: Decodable, Sendable {
    let totalCount: Int?
    let items: [PathfinderLibraryTrackItem]?
}

/// One saved track.
///
/// **The track does not carry its own uri here**, which is the one thing that makes this shape
/// different from every other track-bearing response: `track.data` holds the name, album, artists
/// and duration, and the uri lives on `track._uri` beside it. A decoder that read `data.uri`
/// would get nil for every row and drop the whole list — so the uri is passed into the
/// conversion rather than looked for inside the entity.
nonisolated struct PathfinderLibraryTrackItem: Decodable, Sendable {
    struct Wrapper: Decodable, Sendable {
        let data: PathfinderTrack?

        /// Spotify's own name for the field, underscore included.
        let uri: String?

        private enum CodingKeys: String, CodingKey {
            case data
            case uri = "_uri"
        }
    }

    let addedAt: PathfinderTimestamp?
    let track: Wrapper?
}

// MARK: - areEntitiesInLibrary

/// `{ "data": { "lookup": [ { "data": { "saved": true } }, … ] } }`
///
/// **The answer is positional**, exactly as `/me/tracks/contains` was: `lookup[i]` answers
/// `uris[i]` and nothing in the response names which uri it is about. So the request order is
/// the only thing tying answers to questions, and `statuses(for:)` is the only place that
/// knowledge lives.
///
/// Two ways an entry can fail to say "saved", both measured on 2026-08-13:
///
/// - a uri that resolves to nothing comes back as `data.__typename == "NotFound"` with no
///   `saved` field;
/// - a **playlist** uri comes back as a bare `PlaylistResponseWrapper` with no `data` at all,
///   because this document's selection does not cover playlists.
///
/// Both read as "not saved", which matches what `/v1/me/tracks/contains` answered for an id it
/// did not know. Only tracks are asked about in practice.
nonisolated struct PathfinderLibraryMembershipResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Entity: Decodable, Sendable {
            let saved: Bool?
        }

        let data: Entity?
    }

    struct Payload: Decodable, Sendable {
        let lookup: [Entry]?
    }

    let data: Payload?

    /// Matches each answer back to the uri that asked it, keyed by the **id** the store uses.
    ///
    /// A short `lookup` — fewer answers than questions — leaves the unanswered uris out of the
    /// result rather than defaulting them, so an unanswered track stays unresolved and is asked
    /// about again, instead of being cached as "not a favorite" on the strength of a truncated
    /// response.
    func statuses(for uris: [String]) -> [String: Bool] {
        let lookup = data?.lookup ?? []

        return zip(uris, lookup).reduce(into: [:]) { result, pair in
            guard let id = SpotifyURI.id(from: pair.0) else { return }
            result[id] = pair.1.data?.saved ?? false
        }
    }
}

// MARK: - Variables

/// The variables `libraryV3` takes.
///
/// **Every field here is optional to Spotify** — the document accepts no variables at all and
/// answers with the whole library. That is a hazard rather than a convenience: an unrecognised
/// filter is *silently ignored* rather than rejected, so a typo returns everything the user has
/// saved instead of an error. Measured by sending `PROBE_INVALID_MEMBER`, which answered HTTP 200
/// with no errors and a full library. Hence `LibraryFilter` — the strings are not spelled at any
/// call site.
/// **`flatten` decides whether folders exist**, and the default here is the one that matches
/// what the app can show. Measured on 2026-08-13 against an account with four folders:
///
/// | `flatten` | `includeFoldersWhenFlattening` | result |
/// | --- | --- | --- |
/// | `false` | either | 14 items: 10 playlists and 4 folders, folder contents hidden |
/// | `true` | `true` | 38 items: 34 playlists and 4 folders |
/// | `true` | `false` | **34 items: every playlist, no folders** |
///
/// The last row is what `/me/playlists` returned — a flat list including playlists nested in
/// folders, with no folder ever appearing — so the app's existing flat list is a variable pair
/// rather than a feature away. Leaving `flatten` false is what made this migration show four
/// broken folder rows *and* hide the 24 playlists inside them.
nonisolated struct PathfinderLibraryVariables: Encodable, Sendable {
    var filters: [String]
    var offset: Int = 0
    var limit: Int = LibraryFilter.pageLimit
    var order: String?
    var textFilter: String = ""
    var flatten: Bool = true
    var expandedFolders: [String] = []
    var folderUri: String?
    var includeFoldersWhenFlattening: Bool = false
}

/// The library kinds this app asks for.
///
/// `Audiobooks` is deliberately absent: the account in testing had two, `libraryV3` will happily
/// return them, and the app has no screen, entity or player path for one. Not asking is the whole
/// of "handling" them — there is no partial support to build, and a placeholder row that cannot
/// be opened would be worse than an absence.
nonisolated enum LibraryFilter {
    static let playlists = "Playlists"
    static let artists = "Artists"
    static let albums = "Albums"

    /// What one request returns at most. Measured: 60 followed artists came back as 50 with
    /// `limit: 50`, and `offset: 50` returned the remaining 10 — so the list pages by offset and
    /// this is a ceiling rather than a preference.
    static let pageLimit = 50
}

/// The variables `fetchLibraryTracks` takes. It pages the same way, and reports its own
/// `pagingInfo` back.
nonisolated struct PathfinderLibraryTracksVariables: Encodable, Sendable {
    var offset: Int = 0
    var limit: Int = 50
}

/// The variables `areEntitiesInLibrary` takes — declared `[ID!]!`, so it is the one library
/// operation that requires anything at all.
nonisolated struct PathfinderLibraryLookupVariables: Encodable, Sendable {
    var uris: [String]
}

/// The variables both library mutations take.
///
/// One list of uris, of any kind: a track, an album and an artist are saved by the same call
/// with different prefixes, which is why six Web API endpoints collapse into two operations here.
nonisolated struct PathfinderLibraryWriteVariables: Encodable, Sendable {
    var libraryItemUris: [String]
}

// MARK: - Mutation results

/// What `addToLibrary` and `removeFromLibrary` answer with.
///
/// Same trap as the playlist mutations: **a rejected write is HTTP 200** with a `__typename`
/// naming the failure, so the transport's status check cannot see it, and an optimistic update
/// would stand over a write that never happened. Success is recognised by name and everything
/// else is a failure.
///
/// **The response field is not the operation name**, and neither is the payload type — the
/// operation `addToLibrary` answers under `addLibraryItems` with `AddLibraryItemsResponse`, and
/// `removeFromLibrary` under `removeLibraryItems` with `RemoveLibraryItemsResponse`. All four
/// names were measured on 2026-08-13 rather than derived from the operation: the obvious
/// symmetry with the playlist mutations (`addToPlaylist` → `AddItemsToPlaylistPayload`) predicts
/// `AddToLibraryPayload`, which is wrong, and a client that assumed it would treat every
/// successful write as a rejection.
nonisolated struct PathfinderLibraryMutationResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        let __typename: String?
        let message: String?
    }

    struct Payload: Decodable, Sendable {
        let addLibraryItems: Result?
        let removeLibraryItems: Result?

        var result: Result? {
            addLibraryItems ?? removeLibraryItems
        }
    }

    let data: Payload?

    /// The names Spotify returns when the write actually happened.
    private static let successTypes: Set<String> = [
        "AddLibraryItemsResponse",
        "RemoveLibraryItemsResponse",
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
