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
    var path: [NavigationDestination]

    /// Spelled out because the memberwise initializer cannot carry defaults here —
    /// most routes set only a section, and naming the empty fields at every call site
    /// hides the one that distinguishes them.
    init(
        section: NavigationItem?,
        selection: Selection? = nil,
        query: String? = nil,
        path: [NavigationDestination] = [],
    ) {
        self.section = section
        self.selection = selection
        self.query = query
        self.path = path
    }

    static let startpage = Route(section: .startpage)
}
