//
//  TrackRow.swift
//  Spotifly
//
//  Reusable track row component for displaying tracks across different views
//

import SwiftUI

/// A track as a list row: search's Songs, the one list the track table does not show.
struct TrackRow: View {
    let track: Track
    let index: Int? // Optional index, shown as the row's number
    let isCurrentTrack: Bool
    let currentSection: NavigationItem // Current sidebar section (for "Go to" navigation)
    let onDoubleTap: (@MainActor () async -> Void)? // Plays the row, on a double-click or by accessibility

    /// Made once, not in every row's body, so a row hands its artwork the same shape each time
    /// the list redraws.
    private static let artworkShape = AnyShape(.rect(cornerRadius: 4))

    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService

    @State private var isTogglingFavorite = false
    @State private var showNewPlaylistDialog = false
    @State private var showPlaylistAddedSuccess = false

    /// Favorite status from the store (single source of truth)
    private var isFavorited: Bool {
        store.isFavorite(track.id)
    }

    init(
        track: Track,
        index: Int? = nil,
        currentlyPlayingURI: String?,
        currentSection: NavigationItem = .startpage,
        onDoubleTap: (@MainActor () async -> Void)? = nil,
    ) {
        self.track = track
        self.index = index
        isCurrentTrack = currentlyPlayingURI == track.uri
        self.currentSection = currentSection
        self.onDoubleTap = onDoubleTap
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number, index, or now playing indicator
            ZStack {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                } else if let index {
                    Text(verbatim: "\(index + 1)")
                        .foregroundStyle(.secondary)
                }
                // Otherwise no number is shown.
            }
            .font(.caption)
            .frame(width: 30)

            // Album art. A track with none leaves the column out rather than show a placeholder.
            if !track.images.isEmpty {
                Artwork(
                    images: track.images,
                    size: 40,
                    shape: Self.artworkShape,
                    symbol: "music.note",
                    symbolFont: .caption,
                )
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(isCurrentTrack ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(isCurrentTrack ? Color.accentColor : Color.primary)
                    .lineLimit(1)

                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(track.durationFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Heart button (favorite status from store)
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.caption)
                    .foregroundStyle(isFavorited ? .red : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTogglingFavorite)
            .opacity(isTogglingFavorite ? 0.5 : 1.0)
            .named(.favoriteToggle(isFavorited: isFavorited))

            // Context menu (3-dot button)
            Menu {
                TrackContextMenu(
                    track: track,
                    currentSection: currentSection,
                    selectionId: nil,
                    itemUid: nil,
                    showNewPlaylistDialog: $showNewPlaylistDialog,
                    onPlaylistAdded: showSuccessFeedback,
                )
            } label: {
                // A menu takes its accessibility name from its label, not from a modifier.
                Label("action.more", systemImage: showPlaylistAddedSuccess ? "checkmark.circle.fill" : "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(showPlaylistAddedSuccess ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .animation(.easeInOut(duration: 0.2), value: showPlaylistAddedSuccess)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(showPlaylistAddedSuccess)
            .help("action.more")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isCurrentTrack ? Color.accentColor.opacity(0.1) : Color.clear)
        .opacity(track.isPlayable ? 1.0 : 0.5)
        .help(ifAny: track.unplayableMessage)
        .contentShape(Rectangle())
        .contextMenu {
            TrackContextMenu(
                track: track,
                currentSection: currentSection,
                selectionId: nil,
                itemUid: nil,
                showNewPlaylistDialog: $showNewPlaylistDialog,
                onPlaylistAdded: showSuccessFeedback,
            )
        }
        .onTapGesture(count: 2, perform: play)
        // Accessibility has no double-click, so Play is an action on the row, a group that keeps
        // its heart and menu reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(track.name), \(track.artistName)"))
        .accessibilityAction(named: Text("action.play"), play)
        .task(id: track.id) {
            await resolveFavoriteStatusIfNeeded()
        }
        .newPlaylistPrompt(
            isPresented: $showNewPlaylistDialog,
            trackId: track.id,
            onAdded: showSuccessFeedback,
        )
    }

    /// Plays the row's track. One Spotify will not play starts nothing: played, it would only
    /// fail with the same message, and search's double-click starts radio, which is refused too.
    private func play() {
        if let message = track.unplayableMessage {
            playbackViewModel.errorMessage = message
            return
        }
        guard let onDoubleTap else { return }
        Task { await onDoubleTap() }
    }

    /// Toggle favorite using TrackService (optimistic update)
    private func toggleFavorite() {
        Task {
            isTogglingFavorite = true

            do {
                try await trackService.toggleFavorite(trackId: track.id)
            } catch {
                playbackViewModel.errorMessage = String(localized: "error.update_favorite \(error.localizedDescription)")
            }

            isTogglingFavorite = false
        }
    }

    private func resolveFavoriteStatusIfNeeded() async {
        await trackService.ensureFavoriteStatuses(trackIds: [track.id])
    }

    private func showSuccessFeedback() {
        showPlaylistAddedSuccess = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showPlaylistAddedSuccess = false
        }
    }
}

// MARK: - New Playlist Prompt

/// The "New Playlist…" dialog, and the create-then-add behind it.
///
/// Two places offer it — a track row's menu and the now-playing bar's — with the same dialog,
/// the same two calls in the same order and the same failure sink. The name being typed lives
/// here rather than in either host, since neither has any other use for it.
///
/// The checkmark that follows a successful add does *not* live here: it is drawn on the host's
/// own button, and a track row shows it for its right-click menu too. So the host keeps that
/// flag and hands the prompt a way to raise it.
struct NewPlaylistPrompt: ViewModifier {
    @Binding var isPresented: Bool
    /// The track to put in the new playlist — optional because the now-playing bar carries the
    /// prompt whether or not something is playing.
    let trackId: String?
    let onAdded: () -> Void
    /// Where the new playlist is wanted, such as opening it; told after the track is added.
    var onCreated: (Playlist) -> Void = { _ in }

    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    @State private var newPlaylistName = ""

    func body(content: Content) -> some View {
        content
            .alert("playlist.new.title", isPresented: $isPresented) {
                TextField("playlist.new.placeholder", text: $newPlaylistName)
                Button("action.cancel", role: .cancel) {
                    newPlaylistName = ""
                }
                Button("action.create") {
                    createAndAddToPlaylist(name: newPlaylistName)
                    newPlaylistName = ""
                }
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("playlist.new.message")
            }
    }

    private func createAndAddToPlaylist(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        Task {
            do {
                let newPlaylist = try await playlistService.createPlaylist(name: trimmedName)
                // Empty without a track, as the toolbar's New Playlist makes it.
                if let trackId {
                    try await playlistService.addTracksToPlaylist(
                        playlistId: newPlaylist.id,
                        trackIds: [trackId],
                    )
                }
                onAdded()
                onCreated(newPlaylist)
            } catch {
                playbackViewModel.errorMessage = String(localized: "error.create_playlist \(error.localizedDescription)")
            }
        }
    }
}

extension LocalizedStringKey {
    /// What saving or removing a track is called, in the track menu and on its hearts.
    static func favoriteToggle(isFavorited: Bool) -> LocalizedStringKey {
        isFavorited ? "track.menu.remove_from_favorites" : "track.menu.add_to_favorites"
    }
}

extension View {
    /// A tooltip only where there is something to say. An outer tooltip wins over an inner one,
    /// even an empty one: a row's `.help("")` hid its heart's.
    @ViewBuilder
    func help(ifAny message: String?) -> some View {
        if let message {
            help(message)
        } else {
            self
        }
    }

    func newPlaylistPrompt(
        isPresented: Binding<Bool>,
        trackId: String?,
        onAdded: @escaping () -> Void,
        onCreated: @escaping (Playlist) -> Void = { _ in },
    ) -> some View {
        modifier(NewPlaylistPrompt(
            isPresented: isPresented,
            trackId: trackId,
            onAdded: onAdded,
            onCreated: onCreated,
        ))
    }
}
