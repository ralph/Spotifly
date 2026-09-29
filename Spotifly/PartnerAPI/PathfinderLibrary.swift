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
/// The entity is nested under `item.data`, beside the entry's own `addedAt` and `pinned`, which
/// is why this type exists at all instead of the page holding entities directly. The wrapper
/// also carries a `_uri`, which is not read: the entity has its own `uri` for the three kinds
/// the app stores.
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

// MARK: - Liked Songs

/// Liked Songs, read as the playlist Spotify's own clients now read it as.
///
/// **One uri, not one per account.** `spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ` is a constant in
/// the web player's bundle (beside "Your Episodes", `37i9dQZF1FgnTBfUlzkeKt`), so every
/// account's web player asks for the same one and the service answers with the caller's own
/// songs. The web player switched to it behind two flags, `enableLikedSongsListPlatform` and
/// `enableLikedSongsAsPlaylist`, both on by default: `/collection/tracks` pages with
/// `fetchPlaylist`/`fetchPlaylistContents`, and playing Liked Songs swaps
/// `spotify:collection:tracks` for this uri. The `fetchLibraryTracks` operation this replaces is
/// still in the bundle and still answers, but the web client no longer calls it.
///
/// **The list and the playback context have to be the same thing**, because the favorites view
/// starts playback by index. `spotify:collection:tracks` resolves to the same songs in a
/// different order wherever several share an `addedAt` to the second: measured on 2026-09-29,
/// 121 of 609 rows sat at an index where it held another song. This playlist resolves in exactly
/// the order `fetchPlaylistContents` pages it.
///
/// Writes stay on `addToLibrary`/`removeFromLibrary`: the playlist is a view of the collection,
/// not a playlist anyone edits.
nonisolated enum LikedSongs {
    static let uri = "spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ"

    /// One page of the favorites list. Only a page, not the whole list: the view loads more as
    /// it scrolls.
    static let pageLimit = 50
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

/// What `addToLibrary` and `removeFromLibrary` answer with. Same trap as the playlist mutations,
/// and the same reading of it — see `PathfinderMutationResult`.
///
/// **The response field is not the operation name**, and neither is the payload type — the
/// operation `addToLibrary` answers under `addLibraryItems` with `AddLibraryItemsResponse`, and
/// `removeFromLibrary` under `removeLibraryItems` with `RemoveLibraryItemsResponse`. All four
/// names were measured on 2026-08-13 rather than derived from the operation: the obvious
/// symmetry with the playlist mutations (`addToPlaylist` → `AddItemsToPlaylistPayload`) predicts
/// `AddToLibraryPayload`, which is wrong, and a client that assumed it would treat every
/// successful write as a rejection.
nonisolated struct PathfinderLibraryMutationResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let addLibraryItems: PathfinderMutationResult?
        let removeLibraryItems: PathfinderMutationResult?

        var result: PathfinderMutationResult? {
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
        PathfinderMutationResult.failure(data?.result, unless: Self.successTypes)
    }
}
