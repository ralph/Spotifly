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
