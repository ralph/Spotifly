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
