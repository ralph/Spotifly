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
    case speakers

    var id: String {
        switch self {
        case .startpage: "startpage"
        case .searchResults: "searchResults"
        case .favorites: "favorites"
        case .playlists: "playlists"
        case .albums: "albums"
        case .artists: "artists"
        case .queue: "queue"
        case .speakers: "speakers"
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
        case .speakers:
            String(localized: "nav.speakers")
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
        case .speakers:
            "hifispeaker.2.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    let onLogout: () -> Void
    var hasSearchResults: Bool = false

    @AppStorage("showSpotifyConnectSpeakers") private var showConnectSpeakers: Bool = false
    @AppStorage("showAirPlaySpeakers") private var showAirPlaySpeakers: Bool = false

    /// Whether to show the speakers item in the sidebar
    private var showSpeakersItem: Bool {
        showConnectSpeakers || showAirPlaySpeakers
    }

    /// Navigation items in the main section (conditionally includes speakers)
    private var mainNavItems: [NavigationItem] {
        var items: [NavigationItem] = [.startpage, .queue]
        if showSpeakersItem {
            items.append(.speakers)
        }
        return items
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(mainNavItems) { item in
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
