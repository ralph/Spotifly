//
//  SidebarView.swift
//  Spotifly
//
//  Navigation sidebar for authenticated view
//

import SwiftUI
#if canImport(AppKit)
    import AppKit
#endif

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
            "opticaldisc"
        case .artists:
            "mic.fill"
        case .queue:
            "text.line.first.and.arrowtriangle.forward"
        case .speakers:
            "hifispeaker.2.fill"
        case .profile:
            "person.circle.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    var hasSearchResults: Bool = false
    var userProfile: UserProfile?

    private static let mainNavItems: [NavigationItem] = [.startpage, .queue, .speakers]
    private static let libraryNavItems: [NavigationItem] = [.favorites, .playlists, .albums, .artists]

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(Self.mainNavItems) { item in
                    navigationLink(for: item)
                }
            } header: {
                HStack(spacing: 8) {
                    AppBrandIcon(size: 22)
                    Text("app.name")
                        .font(.headline)
                }
                .padding(.bottom, 8)
            }

            if hasSearchResults {
                Section {
                    navigationLink(for: .searchResults)
                }
            }

            Section {
                ForEach(Self.libraryNavItems) { item in
                    navigationLink(for: item)
                }
            } header: {
                Text("nav.library")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                // Opens the native macOS Preferences window (Settings scene).
                SettingsLink {
                    Label("nav.settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Button {
                    selection = .profile
                } label: {
                    HStack(spacing: 8) {
                        ProfileAvatarView(userProfile: userProfile, size: 28)
                        Text(userProfile?.displayName ?? String(localized: "nav.profile"))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selection == .profile
                                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1),
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .navigationTitle("app.name")
    }

    private func navigationLink(for item: NavigationItem) -> some View {
        NavigationLink(value: item) {
            Label(item.title, systemImage: item.icon)
        }
    }
}

// MARK: - App Brand Icon

/// The app's real icon (the same one shown in the Dock), used as the sidebar brand mark.
struct AppBrandIcon: View {
    var size: CGFloat = 22

    var body: some View {
        #if canImport(AppKit)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        #else
            Image(systemName: "music.note.list")
                .foregroundStyle(.green)
                .frame(width: size, height: size)
        #endif
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
