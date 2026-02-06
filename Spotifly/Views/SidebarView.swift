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
    case profile

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
        case .profile: "profile"
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
        case .profile:
            String(localized: "nav.profile")
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
            "mic.fill"
        case .queue:
            "list.bullet"
        case .speakers:
            "hifispeaker.2.fill"
        case .profile:
            "person.circle.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    let onLogout: () -> Void
    var hasSearchResults: Bool = false
    var userProfile: UserProfile?

    /// Navigation items in the main section
    private var mainNavItems: [NavigationItem] {
        [.startpage, .queue, .speakers]
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
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                selection = .profile
            } label: {
                HStack(spacing: 8) {
                    ProfileAvatarView(userProfile: userProfile, size: 28)
                    Text(userProfile?.displayName ?? String(localized: "nav.profile"))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selection == .profile ? AnyShapeStyle(.selection.opacity(0.8)) : AnyShapeStyle(.clear)),
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .navigationTitle("app.name")
    }
}

// MARK: - Profile Avatar

struct ProfileAvatarView: View {
    let userProfile: UserProfile?
    var size: CGFloat = 32

    var body: some View {
        if let imageURL = userProfile?.imageURL {
            AsyncImage(url: imageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                initialsView(for: userProfile?.displayName)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else if let displayName = userProfile?.displayName {
            initialsView(for: displayName)
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: size, height: size)
        }
    }

    private func initialsView(for name: String?) -> some View {
        let initials = String((name ?? "?").prefix(2)).uppercased()
        return Circle()
            .fill(.green.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
