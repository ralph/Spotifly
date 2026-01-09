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
}
