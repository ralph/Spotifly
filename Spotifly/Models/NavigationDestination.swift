//
//  NavigationDestination.swift
//  Spotifly
//
//  The drill-downs a route's path can hold.
//

import Foundation

/// A page opened from within a section, such as all of a search's tracks. The last one in the
/// route's path is the page `LoggedInContentRouterView` shows. Holds ids rather than whole
/// objects, to keep the history light and `Hashable`.
enum NavigationDestination: Hashable {
    case artist(id: String)
    case album(id: String)
    case playlist(id: String)
    case searchTracks(ids: [String])
}
