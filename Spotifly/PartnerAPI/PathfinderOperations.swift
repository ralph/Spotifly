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
/// If copying from libspot ever stops being enough, they can be harvested directly: load
/// `open.spotify.com` in a browser, and either read them off the network tab — every
/// `api-partner` request carries `extensions.persistedQuery.sha256Hash` next to its
/// `operationName` — or pull the xpui JavaScript bundles and grep for the operation name, which
/// appears beside its hash in the generated query map. That is how they enter libspot in the
/// first place, and it is worth doing directly only if this list falls behind.
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
