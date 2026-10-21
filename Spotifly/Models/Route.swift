//
//  Route.swift
//  Spotifly
//
//  The complete location of the logged-in shell.
//

import Foundation

/// The kinds of result a search finds, each of which its page can show alone.
enum SearchKind: String, Hashable, CaseIterable, Encodable, CodingKeyRepresentable {
    case tracks
    case artists
    case albums
    case playlists
}

enum Selection: Hashable {
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)

    /// The section whose list holds this kind of selection.
    var section: NavigationItem {
        switch self {
        case .album: .albums
        case .artist: .artists
        case .playlist: .playlists
        }
    }
}

/// The memberwise initializer's defaults leave every field but the section out: most routes set
/// only that one, and naming the empty fields at every call site hides the one that distinguishes
/// them.
struct Route: Hashable {
    var section: NavigationItem?
    var selection: Selection?
    /// A search route's query, or nil for the search page before a search: recent searches.
    var query: String?
    /// The one kind a search route shows, or nil for all of them a few each: a step of its own
    /// in the history, as the web player's search tabs are, drawn from the same search's results.
    var searchScope: SearchKind?

    static let startpage = Route(section: .startpage)
}

extension Route {
    /// A selection's page, in the section that lists its kind.
    init(showing selection: Selection) {
        self.init(section: selection.section, selection: selection)
    }

    /// The page a context uri opens: an album's, an artist's or a playlist's, and Favorites for
    /// Liked Songs, which plays as a playlist no page shows (`LikedSongs.uri`). Nil for a uri
    /// with no page, such as a radio station.
    init?(contextUri uri: String) {
        if uri == LikedSongs.uri {
            self.init(section: .favorites)
        } else if let id = SpotifyURI.id(from: uri, kind: "album") {
            self.init(showing: .album(id: id))
        } else if let id = SpotifyURI.id(from: uri, kind: "artist") {
            self.init(showing: .artist(id: id))
        } else if let id = SpotifyURI.id(from: uri, kind: "playlist") {
            self.init(showing: .playlist(id: id))
        } else {
            return nil
        }
    }
}
