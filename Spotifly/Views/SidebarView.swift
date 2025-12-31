//
//  SidebarView.swift
//  Spotifly
//
//  Navigation sidebar for authenticated view
//

import SwiftUI

enum NavigationItem: Hashable, Identifiable {
    case startpage
    case favorites
    case playlists
    case albums
    case artists
    case queue

    var id: Self { self }

    var title: String {
        switch self {
        case .startpage:
            "Startpage"
        case .favorites:
            "Favorites"
        case .playlists:
            "Playlists"
        case .albums:
            "Albums"
        case .artists:
            "Artists"
        case .queue:
            "Queue"
        }
    }

    var icon: String {
        switch self {
        case .startpage:
            "house.fill"
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
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    let onLogout: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([NavigationItem.startpage, NavigationItem.queue]) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.green)
                    Text("Spotifly")
                        .font(.headline)
                }
                .padding(.bottom, 8)
            }

            Section("Library") {
                ForEach([NavigationItem.favorites, NavigationItem.playlists, NavigationItem.albums, NavigationItem.artists]) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            }

            Section {
                Button(action: onLogout) {
                    Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Spotifly")
    }
}
