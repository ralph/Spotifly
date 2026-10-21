//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist with track list, using normalized store
//

import SwiftUI
import UniformTypeIdentifiers

struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var isLoading = false
    @State private var failure: LoadFailure?
    @State private var showEditDetailsDialog = false
    @State private var showCoverPicker = false
    @State private var showRemoveCoverConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showUnfollowConfirmation = false
    @State private var editingPlaylistName = ""
    @State private var editingPlaylistDescription = ""

    /// The playlist from the store — the only copy. Whatever a load puts there
    /// shows up here, including a load whose original view was torn down mid-flight.
    private var playlist: Playlist? {
        store.playlists[playlistId]
    }

    private var playlistName: String {
        playlist?.name ?? ""
    }

    private var playlistDescription: String {
        playlist?.description ?? ""
    }

    /// Tracks from the store for this playlist
    private var tracks: [Track] {
        rows.map(\.track)
    }

    /// The playlist's entries paired with their tracks.
    ///
    /// Rows carry their `PlaylistItem`, not just a track, because reordering and removal name
    /// the **occurrence**: a playlist can hold one song twice, and a row that knows only its
    /// track cannot say which of the two it is.
    private var rows: [(item: PlaylistItem, track: Track)] {
        (playlist?.items ?? []).compactMap { item in
            store.tracks[item.trackId].map { (item, $0) }
        }
    }

    /// Whether the current user owns this playlist
    private var isOwner: Bool {
        playlist?.ownerId == store.userId
    }

    var body: some View {
        // A ZStack, not a Group: a Group hands its `.task` to each branch, so switching
        // between loading and the error started the load again, forever.
        ZStack {
            if let playlist {
                playlistContent(playlist)
            } else if let failure {
                InlineLoadError(failure: failure) { await loadPlaylist() }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(playlistName)
        .task(id: playlistId) {
            await loadPlaylist()
        }
        .alert("playlist.edit_details.title", isPresented: $showEditDetailsDialog) {
            TextField("playlist.edit_details.name", text: $editingPlaylistName)
            TextField("playlist.edit_details.description", text: $editingPlaylistDescription)
            Button("action.cancel", role: .cancel) {
                editingPlaylistName = ""
                editingPlaylistDescription = ""
            }
            Button("playlist.edit_details.save") {
                savePlaylistDetails()
            }
            .disabled(editingPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("playlist.edit_details.message")
        }
        .alert("playlist.delete.title", isPresented: $showDeleteConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("playlist.delete.action", role: .destructive) {
                deletePlaylist()
            }
        } message: {
            Text("playlist.delete.message \(playlistName)")
        }
        .alert("playlist.unfollow.title", isPresented: $showUnfollowConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("playlist.unfollow.action", role: .destructive) {
                unfollowPlaylist()
            }
        } message: {
            Text("playlist.unfollow.message \(playlistName)")
        }
        .onToolbarAction(.showPlaylistEditDetails, addressedTo: playlistId) {
            editingPlaylistName = playlistName
            editingPlaylistDescription = playlistDescription
            showEditDetailsDialog = true
        }
        .fileImporter(isPresented: $showCoverPicker, allowedContentTypes: [.image]) { picked in
            updating { try await playlistService.changePlaylistCover(playlistId: playlistId, imageAt: picked.get()) }
        }
        .alert("playlist.remove_cover.title", isPresented: $showRemoveCoverConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("playlist.remove_cover.action", role: .destructive) {
                updating { try await playlistService.removePlaylistCover(playlistId: playlistId) }
            }
        } message: {
            Text("playlist.remove_cover.message")
        }
        .onToolbarAction(.showPlaylistCoverPicker, addressedTo: playlistId) {
            showCoverPicker = true
        }
        .onToolbarAction(.showPlaylistRemoveCoverConfirmation, addressedTo: playlistId) {
            showRemoveCoverConfirmation = true
        }
        .onToolbarAction(.showPlaylistDeleteConfirmation, addressedTo: playlistId) {
            showDeleteConfirmation = true
        }
        .onToolbarAction(.showPlaylistUnfollowConfirmation, addressedTo: playlistId) {
            showUnfollowConfirmation = true
        }
    }

    private func playlistContent(_ playlist: Playlist) -> some View {
        // Built once per redraw: a playlist can hold thousands of rows, and each read of `rows`
        // looks every track up again (`plans/done/playlist-rows-built-once-per-row.md`).
        let rows = rows
        let tracks = rows.map(\.track)

        return VStack(spacing: 0) {
            header(playlist, tracks: tracks)

            if isLoading, tracks.isEmpty {
                ProgressView("loading.tracks")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure, tracks.isEmpty {
                InlineLoadError(failure: failure) { await reloadTracks() }
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                // A failed edit, delete, unfollow or move over the rows there are, with a retry
                // that reads the playlist again.
                if let failure {
                    InlineLoadError(failure: failure) { await reloadTracks() }
                        .padding(.bottom, 8)
                }
                TrackTable(
                    rows: tableRows(rows),
                    columns: [.number, .album],
                    currentSection: .playlists,
                    selectionId: playlistId,
                    // Only one's own playlist takes a move.
                    reorder: isOwner ? { @MainActor @Sendable uid, index in move(uid: uid, toInsertionIndex: index) } : nil,
                ) { row in
                    Task {
                        await playbackViewModel.play(uriOrUrl: playlist.uri, trackIndex: row.number - 1, startingAtUri: row.track.uri)
                    }
                }
            }
        }
    }

    /// The rows, each named by its item's uid: a playlist can hold one song twice, and moving
    /// or removing a row names the occurrence.
    private func tableRows(_ rows: [(item: PlaylistItem, track: Track)]) -> [TrackTableRow] {
        rows.enumerated().map { index, row in
            TrackTableRow(id: row.item.uid, number: index + 1, track: row.track, itemUid: row.item.uid)
        }
    }

    private var isFollowed: Bool {
        store.userPlaylistIds.contains(playlistId)
    }

    private func header(_ playlist: Playlist, tracks: [Track]) -> some View {
        DetailHeader(
            kind: isOwner || !isFollowed ? String(localized: "detail.kind.playlist") : String(localized: "detail.kind.followed_playlist"),
            title: playlistName,
            description: playlistDescription,
        ) {
            Artwork.detailHeader(playlist.images, symbol: "music.note.list")
        } metadata: {
            Text(verbatim: metadataLine(
                localizedTextString("metadata.by_owner", playlist.ownerName),
                localizedNumberString("metadata.tracks", tracks.isEmpty ? playlist.trackCount : tracks.count),
                tracks.isEmpty ? nil : totalDuration(of: tracks),
            ))
        } actions: {
            PlayAndShuffleButtons {
                playAllTracks()
            } shuffle: {
                Task { await playbackViewModel.playShuffled(uriOrUrl: playlist.uri, trackUris: tracks.map(\.uri)) }
            }
            .disabled(tracks.isEmpty)

            // Someone else's playlist is in the library or not; one's own always is.
            if !isOwner {
                LibraryToggleButton(isOn: isFollowed) {
                    updating { try await playlistService.followPlaylist(playlistId: playlistId) }
                } confirmRemoval: {
                    showUnfollowConfirmation = true
                }
            }
        }
    }

    /// Moves a row to sit before the row now at `index`, or last past the end: first in the
    /// store, so the table shows it at once, then on Spotify, named by uids. A failure reads the
    /// playlist again, so the list on screen is the one Spotify has.
    private func move(uid: String, toInsertionIndex index: Int) {
        guard let items = store.playlists[playlistId]?.items,
              let from = items.firstIndex(where: { $0.uid == uid }),
              index != from, index != from + 1
        else { return }
        let beforeUid = index < items.count ? items[index].uid : nil

        withAnimation {
            playlistService.previewMove(playlistId: playlistId, fromIndex: from, toIndex: index > from ? index - 1 : index)
        }
        Task {
            do {
                try await playlistService.movePlaylistItem(playlistId: playlistId, uid: uid, beforeUid: beforeUid)
            } catch {
                // A newer move cancelled this one's reconciliation, and owns the order now.
                guard !isCancellation(error) else { return }
                debugLog("PlaylistReorder", "Failed to reorder: \(error)")
                do {
                    try await playlistService.reloadPlaylistTracks(playlistId: playlistId)
                } catch {
                    failure = LoadFailure(message: String(localized: "error.reorder_tracks \(error.localizedDescription)"))
                }
            }
        }
    }

    private func deletePlaylist() {
        Task {
            do {
                try await playlistService.deletePlaylist(playlistId: playlistId)
                // Navigate away from the deleted playlist
                navigationCoordinator.clearPlaylistSelection()
            } catch {
                failure = LoadFailure(message: String(localized: "error.delete_playlist \(error.localizedDescription)"))
            }
        }
    }

    private func unfollowPlaylist() {
        Task {
            do {
                try await playlistService.unfollowPlaylist(playlistId: playlistId)
                // Navigate away from the unfollowed playlist
                navigationCoordinator.clearPlaylistSelection()
            } catch {
                failure = LoadFailure(message: String(localized: "error.unfollow_playlist \(error.localizedDescription)"))
            }
        }
    }

    private func savePlaylistDetails() {
        let trimmedName = editingPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        // Only a description that was changed, so a rename leaves it alone. The field holds the
        // text the description's HTML reads as; Spotify stores what it's sent and escapes it when
        // read (2026-10-02), so a changed one goes back as typed.
        let description = editingPlaylistDescription == playlistDescription ? nil : editingPlaylistDescription
        editingPlaylistName = ""
        editingPlaylistDescription = ""

        updating {
            try await playlistService.updatePlaylistDetails(playlistId: playlistId, name: trimmedName, description: description)
        }
    }

    /// Runs a change to the playlist, and shows what went wrong where the page shows its errors.
    private func updating(_ change: @escaping () async throws -> Void) {
        Task {
            do {
                try await change()
            } catch {
                failure = LoadFailure(message: String(localized: "error.update_playlist \(error.localizedDescription)"))
            }
        }
    }

    private func loadPlaylist() async {
        // Only claim to be loading when the track list is actually missing —
        // a cached playlist must not flash a spinner over its tracks.
        isLoading = playlist?.tracksLoaded != true
        failure = nil

        do {
            try await playlistService.ensurePlaylistLoaded(playlistId: playlistId)
        } catch {
            // A cancellation is this view going away, not a failure: the load keeps
            // running and its result is in the store for whatever replaces us.
            if !isCancellation(error) {
                failure = LoadFailure(error)
            }
        }

        isLoading = false
    }

    /// The track-list retry. It re-fetches unconditionally rather than going through
    /// `ensurePlaylistLoaded`, because the message it sits under can be a failed
    /// reorder rollback — where the store holds a track list that *is* loaded and
    /// wrong, so the cache-respecting call would fetch nothing.
    private func reloadTracks() async {
        isLoading = true
        failure = nil

        do {
            try await playlistService.reloadPlaylistTracks(playlistId: playlistId)
        } catch {
            if !isCancellation(error) {
                failure = LoadFailure(error)
            }
        }

        isLoading = false
    }

    private func playAllTracks() {
        guard let playlist else { return }
        Task {
            // Use playlist URI to load via Spirc.load(LoadRequest::from_context_uri())
            // This properly loads the playlist context instead of individual tracks
            await playbackViewModel.play(uriOrUrl: playlist.uri)
        }
    }
}
