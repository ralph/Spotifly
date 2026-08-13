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
/// the request starts failing (`PersistedQueryNotFound`). The values below were taken from the
/// libspot checkout (`pathfinder/pfrequest/operations.go`), which is the upstream to watch when
/// something stops resolving.
///
/// **When libspot is not enough**, harvest them from the live web client:
/// `libspot-probe/harvest-hashes.sh [pattern]` fetches the current bundle and prints every
/// operation with its hash. That is already necessary rather than hypothetical — `getAlbum`
/// came from there, because libspot declares the operation and then panics.
///
/// A harvested hash is a *candidate* until the service answers it. The web client's search
/// hashes differ from the libspot ones below and both work today, so the two sources are simply
/// different releases: newer does not mean the older one is dead. libspot's were vendored on
/// 2026-05-22 and were still being accepted twelve weeks later, which is the useful thing to
/// know about how fast these actually rot.
nonisolated struct PathfinderOperation: Sendable, Equatable {
    let name: String
    let sha256Hash: String

    static let searchTracks = PathfinderOperation(
        name: "searchTracks",
        sha256Hash: "59ee4a659c32e9ad894a71308207594a65ba67bb6b632b183abe97303a51fa55",
    )

    static let searchAlbums = PathfinderOperation(
        name: "searchAlbums",
        sha256Hash: "5e7d2724fbef31a25f714844bf1313ffc748ebd4bd199eaad50628a4f246a7ab",
    )

    static let searchArtists = PathfinderOperation(
        name: "searchArtists",
        sha256Hash: "72c8c7c1e789a9f11e261c4f9ae35a9465bbb90137c584428989573617b6c08d",
    )

    static let searchPlaylists = PathfinderOperation(
        name: "searchPlaylists",
        sha256Hash: "af1730623dc1248b75a61a18bad1f47f1fc7eff802fb0676683de88815c958d8",
    )

    /// Album details *and* its track list in one response — the whole album view.
    ///
    /// **Harvested from the web client, not from libspot**, which is the first operation here
    /// that had to be: libspot declares `OpGetAlbum` and then falls through to
    /// `panic("not implemented")`, so there was nothing to copy. Taken on 2026-08-13 from
    /// `open.spotifycdn.com/cdn/build/web-player/web-player.765d5916.js`, where every operation
    /// is constructed as `new n.l(name, "query", sha256Hash, null)` — grep that shape for the
    /// operation name. Verified against the live service before use, which matters more than
    /// where it came from: the web client's *search* hashes differ from the libspot ones above
    /// and both are currently accepted, so a bundle and a checkout are simply two releases.
    static let getAlbum = PathfinderOperation(
        name: "getAlbum",
        sha256Hash: "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
    )

    /// Who the artist is: name and images. Also carries a *sample* of the discography, which
    /// is why the full list comes from `queryArtistDiscographyAll` instead — this one returns
    /// ten albums of fifteen and ten singles of twenty-one, and the artist page offers "show
    /// all".
    static let queryArtistOverview = PathfinderOperation(
        name: "queryArtistOverview",
        sha256Hash: "ae0e2958a4ab645b35ca19ac04d0495ae12d9c5d7b7286217674801a9aab281a",
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
        sha256Hash: "86dde7b9d9356e2369414647cf6950cfed96e778e129cfdfc99aea6c1613b3b0",
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
}

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
