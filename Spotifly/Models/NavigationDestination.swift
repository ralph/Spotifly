//
//  NavigationDestination.swift
//  Spotifly
//
//  Types that can be pushed onto the navigation stack for drill-down navigation.
//

import Foundation

/// Navigation destinations for stack-based navigation
/// Uses IDs instead of full objects to keep NavigationPath lightweight and Hashable
enum NavigationDestination: Hashable {
    case artist(id: String)
    case album(id: String)
    case playlist(id: String)
    case searchTracks(tracks: [Track])
}

// Make Track array hashable for NavigationDestination
extension NavigationDestination {
    func hash(into hasher: inout Hasher) {
        switch self {
        case let .artist(id):
            hasher.combine("artist")
            hasher.combine(id)
        case let .album(id):
            hasher.combine("album")
            hasher.combine(id)
        case let .playlist(id):
            hasher.combine("playlist")
            hasher.combine(id)
        case let .searchTracks(tracks):
            hasher.combine("searchTracks")
            hasher.combine(tracks.map(\.id))
        }
    }

    static func == (lhs: NavigationDestination, rhs: NavigationDestination) -> Bool {
        switch (lhs, rhs) {
        case let (.artist(lhsId), .artist(rhsId)):
            lhsId == rhsId
        case let (.album(lhsId), .album(rhsId)):
            lhsId == rhsId
        case let (.playlist(lhsId), .playlist(rhsId)):
            lhsId == rhsId
        case let (.searchTracks(lhsTracks), .searchTracks(rhsTracks)):
            lhsTracks.map(\.id) == rhsTracks.map(\.id)
        default:
            false
        }
    }
}
