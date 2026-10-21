//
//  StartpageView.swift
//  Spotifly
//
//  The start page: what was played last, the listener's top tracks and artists, and playlists.
//

import SwiftUI

/// The start page, in the redesign's four sections (`plans/done/redesign-home.md`).
///
/// "Zuletzt gehört" is one shelf of Spotify's own `home` page, the one that lists the contexts
/// last played; the top tracks and artists come from `userTopContent`, a range at a time; the
/// playlists are the library's.
struct StartpageView: View {
    @Environment(AppStore.self) private var store
    @Environment(HomeService.self) private var homeService
    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    /// The top tracks' range, kept across launches.
    @AppStorage("startpageTopTracksRange") private var range: TopContentRange = .mid
    @State private var topContentFailed = false

    /// How many playlists the row shows; "Alle anzeigen" opens the rest.
    private static let playlistLimit = 9
    /// The handoff's card side on this page; artists' are 130.
    private static let cardSize: CGFloat = 150

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let recent = store.recentlyPlayedSection {
                    SectionHeader(Text("home.recently_played"))
                    CardRow {
                        ForEach(recent.items) { item in
                            card(for: item)
                        }
                    }
                }

                SectionHeader(title: Text("home.top_tracks")) {
                    Picker("home.range", selection: $range) {
                        ForEach(TopContentRange.allCases, id: \.self) { range in
                            Text(range.titleKey).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                topTracks

                if !topArtists.isEmpty {
                    SectionHeader(Text("home.top_artists"))
                    CardRow {
                        ForEach(topArtists) { artist in
                            ArtistCard(artist: artist, size: 130)
                        }
                    }
                }

                if !playlists.isEmpty {
                    SectionHeader(title: Text("home.your_playlists")) {
                        Button("home.show_all") {
                            navigationCoordinator.selectNavigationItem(.playlists)
                        }
                        .buttonStyle(.link)
                    }
                    CardRow {
                        ForEach(playlists) { playlist in
                            PlaylistCard(playlist: playlist, subtitle: subtitle(for: playlist), size: Self.cardSize)
                        }
                    }
                }

                if store.homeSections.isEmpty, store.topContent.isEmpty {
                    placeholder
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable {
            await homeService.refresh()
        }
        // The library's playlists, which otherwise load only when Playlists opens.
        .task {
            if !store.playlistsPagination.isLoaded {
                try? await playlistService.loadUserPlaylists()
            }
        }
        // Tracks and artists, both over the picker's range.
        .task(id: range) {
            await loadTopContent()
        }
    }

    /// Loads the picker's range, and remembers when that left it absent: a failed load stores
    /// nothing, and the section would otherwise wait forever.
    private func loadTopContent() async {
        topContentFailed = false
        await homeService.loadTopContent(range: range)
        // A load superseded by another range's leaves the state to that one.
        guard !Task.isCancelled else { return }
        topContentFailed = store.topContent[range] == nil
    }

    // MARK: - Sections

    /// An id with no entity draws nothing: the shelf is stored as ids, and a card cannot be drawn
    /// from one alone.
    @ViewBuilder
    private func card(for item: HomeItem) -> some View {
        switch item {
        case let .album(id):
            if let album = store.albums[id] {
                AlbumCard(album: album, size: Self.cardSize)
            }
        case let .playlist(id):
            if let playlist = store.playlists[id] {
                PlaylistCard(playlist: playlist, subtitle: subtitle(for: playlist), size: Self.cardSize)
            }
        case let .artist(id):
            if let artist = store.artists[id] {
                ArtistCard(artist: artist, size: Self.cardSize)
            }
        }
    }

    // MARK: - Top tracks

    private var topTrackList: [Track] {
        (store.topContent[range]?.trackIds ?? []).compactMap { store.tracks[$0] }
    }

    private var topArtists: [Artist] {
        (store.topContent[range]?.artistIds ?? []).compactMap { store.artists[$0] }
    }

    @ViewBuilder
    private var topTracks: some View {
        let tracks = topTrackList
        if topContentFailed {
            HStack {
                Text("home.top_content_failed")
                    .foregroundStyle(.secondary)
                Button("action.try_again") {
                    Task { await loadTopContent() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        } else if store.topContent[range] == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 2) {
                ForEach(tracks.enumerated(), id: \.element.id) { index, track in
                    TopTrackRow(rank: index + 1, track: track)
                        .onTapGesture(count: 2) {
                            play(tracks, from: index)
                        }
                }
            }
            .padding(.horizontal, 28)
        }
    }

    /// Plays the top tracks as a list, from the one double-clicked. One Spotify will not play
    /// starts nothing, as in every list.
    private func play(_ tracks: [Track], from index: Int) {
        if let message = tracks[index].unplayableMessage {
            playbackViewModel.errorMessage = message
            return
        }
        Task {
            await playbackViewModel.playTracks(tracks[index...].map(\.uri))
        }
    }

    // MARK: - Playlists

    private var playlists: [Playlist] {
        store.userPlaylistIds.prefix(Self.playlistLimit).compactMap { store.playlists[$0] }
    }

    /// Its owner. The handoff gives the listener's own playlists their track count, which the
    /// library and the home page do not name: they record an unknown count as 0.
    private func subtitle(for playlist: Playlist) -> String {
        localizedTextString("metadata.by_owner", playlist.ownerName)
    }

    // MARK: - Empty

    /// Loading, failure and "Spotify sent nothing" share a frame rather than three blocks.
    private var placeholder: some View {
        Group {
            if store.homeIsLoading {
                ProgressView()
            } else if let error = store.homeErrorMessage {
                ContentUnavailableView {
                    Label("startpage.error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("action.try_again") {
                        Task { await homeService.refresh() }
                    }
                }
            } else {
                ContentUnavailableView(
                    "startpage.empty",
                    systemImage: "house",
                    description: Text("startpage.empty.description"),
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Top track row

/// One of the top tracks: its rank, a 36 pt cover, title over artist, and a separator under it.
private struct TopTrackRow: View {
    let rank: Int
    let track: Track

    var body: some View {
        HStack(spacing: 10) {
            Text(rank, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 18, alignment: .trailing)

            Artwork(
                images: track.images,
                size: 36,
                shape: Self.artworkShape,
                symbol: "music.note",
                symbolFont: .caption,
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .contentShape(.rect)
        .opacity(track.isPlayable ? 1 : 0.5)
        .help(ifAny: track.unplayableMessage)
    }

    /// Built once rather than on every redraw, as `TrackRow`'s is.
    private static let artworkShape = AnyShape(.rect(cornerRadius: 4))
}

private extension TopContentRange {
    var titleKey: LocalizedStringKey {
        switch self {
        case .short: "home.range.short"
        case .mid: "home.range.mid"
        case .long: "home.range.long"
        }
    }
}
