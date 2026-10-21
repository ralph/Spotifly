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
            String(localized: "nav.search")
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
    var userProfile: UserProfile?

    private static let mainNavItems: [NavigationItem] = [.startpage, .searchResults, .queue, .speakers]
    private static let libraryNavItems: [NavigationItem] = [.favorites, .playlists, .albums, .artists]

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(Self.mainNavItems) { item in
                    navigationLink(for: item)
                }
            }

            Section("nav.library") {
                ForEach(Self.libraryNavItems) { item in
                    navigationLink(for: item)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private func navigationLink(for item: NavigationItem) -> some View {
        NavigationLink(value: item) {
            if item == .queue {
                QueueRowLabel()
            } else {
                Label(item.title, systemImage: item.icon)
            }
        }
    }

    /// The account, which opens Profil, and the gear that opens Settings, on one row.
    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                selection = .profile
            } label: {
                HStack(spacing: 8) {
                    ProfileAvatarView(userProfile: userProfile, size: 22)
                    Text(userProfile?.displayName ?? String(localized: "nav.profile"))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(selection == .profile ? 1 : 0), in: .rect(cornerRadius: 7))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            SettingsLink {
                Label("nav.settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .named("nav.settings")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

/// The queue's row, with a badge for the tracks still to come; a count of 0 shows none. A view
/// of its own, so the player's queue redraws this row alone. The badge is on the label, not the
/// link: on the link it took every row's selection highlight away.
private struct QueueRowLabel: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Label(NavigationItem.queue.title, systemImage: NavigationItem.queue.icon)
            .badge(player.queueEntries.nextTracks.count)
    }
}

// MARK: - Profile Avatar

struct ProfileAvatarView: View {
    let userProfile: UserProfile?
    var size: CGFloat = 32

    var body: some View {
        if let imageURL = userProfile?.imageURL {
            RetryingAsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    initialsView(for: userProfile?.displayName)
                }
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
            .fill(Color.accentColor.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
