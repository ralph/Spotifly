//
//  Route.swift
//  Spotifly
//
//  The complete location of the logged-in shell.
//

import Foundation

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

struct Route: Hashable {
    var section: NavigationItem?
    var selection: Selection?
    var query: String?
    /// Defaulted so the memberwise initializer carries defaults for every field but the
    /// section — most routes set only that one, and naming the empty fields at every call
    /// site hides the one that distinguishes them.
    var path: [NavigationDestination] = []

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
