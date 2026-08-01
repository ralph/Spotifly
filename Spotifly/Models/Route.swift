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

    var id: String {
        switch self {
        case let .album(id), let .artist(id), let .playlist(id):
            id
        }
    }
}

struct Route: Hashable {
    var section: NavigationItem?
    var selection: Selection?
    var query: String?
    var path: [NavigationDestination]

    static let startpage = Route(
        section: .startpage,
        selection: nil,
        query: nil,
        path: [],
    )
}
