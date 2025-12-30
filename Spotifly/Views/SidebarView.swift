//
//  SidebarView.swift
//  Spotifly
//
//  Navigation sidebar for authenticated view
//

import SwiftUI

enum NavigationItem: Hashable, Identifiable {
    case startpage
    case playlists

    var id: Self { self }

    var title: String {
        switch self {
        case .startpage:
            "Startpage"
        case .playlists:
            "Playlists"
        }
    }

    var icon: String {
        switch self {
        case .startpage:
            "house.fill"
        case .playlists:
            "music.note.list"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    let onLogout: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([NavigationItem.startpage, NavigationItem.playlists]) { item in
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
