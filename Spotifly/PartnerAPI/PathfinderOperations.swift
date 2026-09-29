//
//  PathfinderOperations.swift
//  Spotifly
//
//  The persisted queries Spotify's own client sends, and their hashes.
//

import Foundation

/// A pathfinder operation: a name, and the hash of the query document Spotify holds for it.
///
/// **The client never sends a query.** `api-partner` speaks persisted queries only: the request
/// carries an operation name, its variables, and a SHA-256 hash that identifies a query
/// document stored on Spotify's side. The field selection therefore lives on their servers —
/// no field can be added or removed here, and the response shape is whatever that document
/// says it is. Only the variables are ours.
///
/// **These hashes are vendored, and they rot.** They are the SHA-256 of the query text
/// Spotify's web client ships, so a new web client release eventually retires the old ones and
/// the request starts failing (`PersistedQueryNotFound`). The live web player is the upstream to
/// watch. As harvested on 2026-09-29, every value below matches
/// `open.spotifycdn.com/cdn/build/web-player/web-player.dea0f59e.js` (the searches:
/// `xpui-routes-search.36497941.js`), where each operation is constructed as
/// `new n.l(name, "query", sha256Hash, null)` — grep that shape for the operation name. The
/// exception is `queryArtistDiscographyAll`, which no loaded script names in that shape; its
/// hash was read off the request the web player sends when an artist's discography opens. The
/// first values came from libspot (`pathfinder/pfrequest/operations.go`) and
/// `libspot-probe/harvest-hashes.sh`; libspot never had `getAlbum`, `home` or the artist
/// operations at all.
///
/// A harvested hash is a *candidate* until the service answers it, and a retired one is not
/// necessarily dead. On 2026-09-29 every hash this replaced was still accepted, so the refresh
/// was verified by sending each operation with *this app's* variables under both the old and the
/// new hash and comparing the answers: every field the decoders read came back identically, and
/// what differed was purely additive (`onPlatformReputationTrait` on search artists, pre-release
/// fields on albums, `meV2` beside `albumUnion`). The web client also sends variables this app
/// does not (`includeAlbumPreReleases`, `includeEpisodeContentRatingsV2: true`, a smaller
/// `limit`); none of them turned out to be required.
nonisolated struct PathfinderOperation: Sendable, Equatable {
    let name: String
    let sha256Hash: String

    static let searchTracks = PathfinderOperation(
        name: "searchTracks",
        sha256Hash: "b02683192a98dde7966b5e6655a79eeb62713eab703eda9902c932818dd52751",
    )

    static let searchAlbums = PathfinderOperation(
        name: "searchAlbums",
        sha256Hash: "202cb3305e31e5a0767ba7925f28bd728cf8f8b0217e6da43909056071cd70e9",
    )

    static let searchArtists = PathfinderOperation(
        name: "searchArtists",
        sha256Hash: "7bf95d754fdbe32c8b161fbbe54d1ae50974900df4dce4c8f1afcbcad153224d",
    )

    static let searchPlaylists = PathfinderOperation(
        name: "searchPlaylists",
        sha256Hash: "d520014e748f9ea44f7707d8df1819867ac1205e8b7f3e28f22fe5fc858921b1",
    )

    /// Album details *and* its track list in one response — the whole album view.
    ///
    /// libspot declares `OpGetAlbum` and then falls through to `panic("not implemented")`, so
    /// this has always come from the web client. The same stored document also defines
    /// `queryAlbumTracks`, which the artist page uses to preview a release. An album that is not
    /// available in the account's market answers `albumUnion: {"__typename": "NotFound"}` with
    /// HTTP 200 rather than an error.
    static let getAlbum = PathfinderOperation(
        name: "getAlbum",
        sha256Hash: "6a74b456cd1735c9193d9e8ec8cc5184cad7ce13572210315229db3975964361",
    )

    /// Who the artist is: name and images. Also carries a *sample* of the discography, which
    /// is why the full list comes from `queryArtistDiscographyAll` instead — this one returns
    /// ten albums of fifteen and ten singles of twenty-one, and the artist page offers "show
    /// all".
    static let queryArtistOverview = PathfinderOperation(
        name: "queryArtistOverview",
        sha256Hash: "9f8134ef565e78621f1e1793555bd6633c5ac144ae0f89604ed3ae3f80b3c8e6",
    )

    /// Every release by an artist, in one list, with no profile beside it.
    ///
    /// Albums, singles and compilations are separate sections in `queryArtistOverview` and one
    /// `all` list here — which matches what the app wants, since it shows a single album list.
    static let queryArtistDiscographyAll = PathfinderOperation(
        name: "queryArtistDiscographyAll",
        sha256Hash: "5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599",
    )

    /// A playlist's details *and* its contents.
    ///
    /// **The name matters more than usual here.** `fetchPlaylist`, `fetchPlaylistContents` and
    /// `fetchPlaylistMetadata` share this hash — one stored document defining three operations
    /// — and `operationName` selects between them. Asking for the wrong one gets a playlist
    /// with no tracks, or tracks with no names, rather than an error.
    static let fetchPlaylist = PathfinderOperation(
        name: "fetchPlaylist",
        sha256Hash: "243c0ba2736f16da721e3a227004bbcdb8df6c846f198bd478172e00aa1faf42",
    )

    /// The playlist mutations, which likewise share one hash and differ by name.
    ///
    /// Their variables were established by sending each with no variables at all: GraphQL
    /// rejects that during validation, before any resolver runs, and names what it wanted —
    /// schema discovery that writes to nobody's playlist. `PlaylistItemPositionInput` came back
    /// as full SDL, doc comments included, from a deliberately invalid field.
    static let addToPlaylist = PathfinderOperation(
        name: "addToPlaylist",
        sha256Hash: playlistMutationHash,
    )

    static let removeFromPlaylist = PathfinderOperation(
        name: "removeFromPlaylist",
        sha256Hash: playlistMutationHash,
    )

    static let moveItemsInPlaylist = PathfinderOperation(
        name: "moveItemsInPlaylist",
        sha256Hash: playlistMutationHash,
    )

    private static let playlistMutationHash =
        "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990"

    /// The user's library — playlists, albums and followed artists — selected by `filters`.
    ///
    /// Three Web API endpoints in one document. Saved *tracks* are not part of it; they have
    /// their own operation below.
    static let libraryV3 = PathfinderOperation(
        name: "libraryV3",
        sha256Hash: "390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455",
    )

    /// The saved tracks, replacing `/me/tracks`.
    static let fetchLibraryTracks = PathfinderOperation(
        name: "fetchLibraryTracks",
        sha256Hash: "087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240",
    )

    /// "Is each of these in the library?", replacing `/me/tracks/contains`. Answers positionally.
    static let areEntitiesInLibrary = PathfinderOperation(
        name: "areEntitiesInLibrary",
        sha256Hash: "134337999233cc6fdd6b1e6dbf94841409f04a946c5c7b744b09ba0dfe5a85ed",
    )

    /// The library writes, which share one hash and differ by name — and which take uris of
    /// *any* kind, so saving a track, saving an album and following an artist are the same call
    /// with different prefixes. Six Web API endpoints collapse into these two.
    static let addToLibrary = PathfinderOperation(
        name: "addToLibrary",
        sha256Hash: libraryMutationHash,
    )

    static let removeFromLibrary = PathfinderOperation(
        name: "removeFromLibrary",
        sha256Hash: libraryMutationHash,
    )

    /// Shared with pin/unpin, which this app does not use.
    private static let libraryMutationHash =
        "1ad0d40b3c09660d818b9e770eb1e84745dfbe941df159a64f8772b6fa2bfc3a"

    /// Spotify's own start page: a greeting and a list of titled shelves.
    ///
    /// Shared with `homeSection` and `homePinnedSections`. This replaced `23e37f2e…`, the
    /// document the decoders in `PathfinderHome.swift` were written against, and the swap was
    /// re-measured rather than assumed, because a different stored document can select different
    /// fields: on 2026-09-29 both answered the same 31 sections with the same 16 albums, 17
    /// artists, 76 playlists and 20 list entities, every decoded field present in the same
    /// places. The new document only adds `isPreRelease` and `preReleaseEndDateTime` to shelf
    /// items and a highlight colour to `homeChips`.
    static let home = PathfinderOperation(
        name: "home",
        sha256Hash: "76243c78b0e20ecdbe41b794dec8cbe73f75e585b0a7201b8d2e84578412847a",
    )

    /// Who the listener is, replacing `/me`.
    static let profileAttributes = PathfinderOperation(
        name: "profileAttributes",
        sha256Hash: "08ffb4730af3746e04a8301396f20875dbbce10c75243803091a9274eacc8ac0",
    )
}

/// For operations that declare no variables at all — `{}` on the wire, which is what the
/// endpoint expects. `profileAttributes` is the only one so far.
nonisolated struct EmptyVariables: Encodable, Sendable {}

/// The variables the artist operations take.
nonisolated struct PathfinderArtistVariables: Encodable, Sendable {
    var uri: String
    var locale: String = ""
    var offset: Int = 0
    var limit: Int = 100
}

/// The variables `getAlbum` takes.
///
/// `limit` is what the web client sets to 300 for an album track list, and no album approaches
/// that. Paging is deliberately not implemented: the response reports `totalCount`, so a short
/// read is detectable rather than silent, and whether `offset` is honoured by this document was
/// not measured — building a paging loop on an unverified offset risks repeating a page forever.
nonisolated struct PathfinderAlbumVariables: Encodable, Sendable {
    var uri: String
    var locale: String = ""
    var offset: Int = 0
    var limit: Int = 300
}

/// The variables every search operation takes.
///
/// The flags are not decoration: the stored query references them, and omitting one Spotify's
/// document expects is a request error rather than a default. These mirror what the web client
/// sends, as recorded in libspot's `defaultSearchCommons`.
nonisolated struct PathfinderSearchVariables: Encodable, Sendable {
    var searchTerm: String
    var offset: Int = 0
    var limit: Int = 30
    var numberOfTopResults: Int = 30
    var includePreReleases: Bool = true
    var includeArtistHasConcertsField: Bool = false
    var includeAudiobooks: Bool = true
    var includeAuthors: Bool = true
    var includeEpisodeContentRatingsV2: Bool = false
}
