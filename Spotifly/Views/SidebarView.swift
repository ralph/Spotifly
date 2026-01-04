//
//  SidebarView.swift
//  Spotifly
//
//  Navigation sidebar for authenticated view
//

import SwiftUI

enum NavigationItem: Hashable, Identifiable {
    case startpage
    case searchResults
    case favorites
    case playlists
    case albums
    case artists
    case queue
    case devices
    case artistContext(artistName: String) // Dynamic artist/album context

    var id: String {
        switch self {
        case .startpage: "startpage"
        case .searchResults: "searchResults"
        case .favorites: "favorites"
        case .playlists: "playlists"
        case .albums: "albums"
        case .artists: "artists"
        case .queue: "queue"
        case .devices: "devices"
        case let .artistContext(name): "artistContext:\(name)"
        }
    }

    var title: String {
        switch self {
        case .startpage:
            String(localized: "nav.startpage")
        case .searchResults:
            String(localized: "nav.search_results")
        case .favorites:
            String(localized: "nav.favorites")
        case .playlists:
            String(localized: "nav.playlists")
        case .albums:
            String(localized: "nav.albums")
        case .artists:
            String(localized: "nav.artists")
        case .queue:
            String(localized: "nav.queue")
        case .devices:
            String(localized: "nav.devices")
        case let .artistContext(artistName):
            artistName
        }
    }

    var icon: String {
        switch self {
        case .startpage:
            "house.fill"
        case .searchResults:
            "magnifyingglass"
        case .favorites:
            "heart.fill"
        case .playlists:
            "music.note.list"
        case .albums:
            "square.stack.fill"
        case .artists:
            "person.2.fill"
        case .queue:
            "list.bullet"
        case .devices:
            "hifispeaker.2.fill"
        case .artistContext:
            "person.circle.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    let onLogout: () -> Void
    var hasSearchResults: Bool = false
    var artistContextItem: NavigationItem? // Dynamic artist context item

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([NavigationItem.startpage, NavigationItem.queue, NavigationItem.devices]) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.green)
                    Text("app.name")
                        .font(.headline)
                }
                .padding(.bottom, 8)
            }

            if hasSearchResults {
                Section {
                    NavigationLink(value: NavigationItem.searchResults) {
                        Label(String(localized: "nav.search_results"), systemImage: "magnifyingglass")
                    }
                }
            }

            // Dynamic artist context section
            if let artistItem = artistContextItem {
                Section {
                    NavigationLink(value: artistItem) {
                        Label(artistItem.title, systemImage: artistItem.icon)
                    }
                }
            }

            Section {
                ForEach([NavigationItem.favorites, NavigationItem.playlists, NavigationItem.albums, NavigationItem.artists]) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            } header: {
                Text("nav.library")
            }

            Section {
                Button(action: onLogout) {
                    Label("auth.logout", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("app.name")
    }
}
