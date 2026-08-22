//
//  StartpageView.swift
//  Spotifly
//
//  Spotify's own start page, as whatever shelves it sends.
//

import SwiftUI

/// The start page.
///
/// **The sections are not this app's to choose.** It used to draw three fixed rows — top
/// artists, top albums, recently played — each with its own request, its own toggle in
/// Preferences and its own "time range" setting, none of which exist on the client APIs. `home`
/// answers with Spotify's own page instead: a greeting and a list of titled shelves that differs
/// between accounts and between refreshes. So this view iterates rather than enumerates, and
/// there is nothing to configure.
struct StartpageView: View {
    @Environment(AppStore.self) private var store
    @Environment(HomeService.self) private var homeService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if store.homeSections.isEmpty {
                    placeholder
                } else {
                    ForEach(store.homeSections) { section in
                        HomeShelf(section: section)
                    }
                }
            }
            .padding(.vertical)
        }
        .contentMargins(.bottom, 100)
        .refreshable {
            await homeService.refresh()
        }
    }

    /// The greeting, and the only sign that a refresh is running.
    ///
    /// **A reload of this page usually changes nothing visible**, which is a property of the
    /// page rather than a bug: two requests a second apart returned an identical first eleven
    /// shelves and differed only in the tail of one-item "Made for you" rows, far below the
    /// fold. So ⌘R looked like a dead key — it fetched, stored and redrew the same page, with
    /// `homeIsLoading` driving only the placeholder, which is hidden whenever there is content
    /// to hide it behind. The spinner is what distinguishes "asked and got the same answer"
    /// from "nothing happened".
    @ViewBuilder
    private var header: some View {
        let greeting = store.homeGreeting ?? ""

        if !greeting.isEmpty || store.homeIsLoading {
            HStack(spacing: 8) {
                Text(greeting)
                    .font(.title2.weight(.semibold))

                if store.homeIsLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
        }
    }

    /// Loading, failure and "Spotify sent nothing" are three states with one row each, so they
    /// share a frame rather than three near-identical blocks.
    private var placeholder: some View {
        VStack(spacing: 16) {
            if store.homeIsLoading {
                ProgressView()
            } else if let error = store.homeErrorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("startpage.error")
                    .font(.headline)
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("action.try_again") {
                    Task { await homeService.refresh() }
                }
            } else {
                Image(systemName: "house")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("startpage.empty")
                    .font(.headline)
                Text("startpage.empty.description")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - One shelf

/// A heading and a horizontal row of cards.
///
/// Reads the entities out of the store by id rather than holding them, so a playlist renamed on
/// its own page is renamed here without the start page reloading.
struct HomeShelf: View {
    let section: HomeSection

    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Spotify sends shelves with no heading — the "shorts" row is one — and an empty
            // `Text` would still take up a line.
            if let title = section.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(section.items) { item in
                        card(for: item)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// An id with no entity draws nothing. That is not defensive: the page is stored as ids, and
    /// a card cannot be drawn from one alone.
    @ViewBuilder
    private func card(for item: HomeItem) -> some View {
        switch item {
        case let .album(id):
            if let album = store.albums[id] {
                AlbumCard(album: album)
            }
        case let .playlist(id):
            if let playlist = store.playlists[id] {
                PlaylistCard(playlist: playlist)
            }
        case let .artist(id):
            if let artist = store.artists[id] {
                ArtistCard(artist: artist)
            }
        }
    }
}
