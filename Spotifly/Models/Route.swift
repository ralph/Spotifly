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
    /// The page a context uri opens: an album's, an artist's or a playlist's, and Favorites for
    /// Liked Songs, which plays as a playlist no page shows (`LikedSongs.uri`). Nil for a uri
    /// with no page, such as a radio station.
    init?(contextUri uri: String) {
        if uri == LikedSongs.uri {
            self.init(section: .favorites)
        } else if let id = SpotifyURI.id(from: uri, kind: "album") {
            self.init(section: .albums, selection: .album(id: id))
        } else if let id = SpotifyURI.id(from: uri, kind: "artist") {
            self.init(section: .artists, selection: .artist(id: id))
        } else if let id = SpotifyURI.id(from: uri, kind: "playlist") {
            self.init(section: .playlists, selection: .playlist(id: id))
        } else {
            return nil
        }
    }
}
