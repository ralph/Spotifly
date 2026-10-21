//
//  TrackTable.swift
//  Spotifly
//
//  The tracks of a list as a sortable table
//

import SwiftUI
import UniformTypeIdentifiers

/// One row of a `TrackTable`: a track at its place in the list it came from.
struct TrackTableRow: Identifiable {
    /// Unique per row, as a track can be listed twice: the item's uid where the list has one.
    let id: String
    /// Its place in the list, from 1, which the # column shows and sorts by.
    let number: Int
    let track: Track
    var addedAt: Date?
    /// The playlist item's uid, which removing it from its playlist names.
    var itemUid: String?
    /// Greyed: in the queue, a row already played or one the player could not name.
    var isDimmed = false
    /// A short tag after the title: in the queue, where the row came from (Q, C, A).
    var tag: String?

    var title: String {
        track.name
    }

    var album: String {
        track.albumName ?? ""
    }

    var addedSortKey: Date {
        addedAt ?? .distantPast
    }

    var durationMs: Int {
        track.durationMs
    }

    /// Whether this row is the one playing.
    ///
    /// **Position wins over uri where the list knows it.** A list can legitimately hold the
    /// same recording twice — an album with a reprise, a playlist a track was added to twice,
    /// or two catalogue entries that relink to one market id (see AGENTS.md, "Relinking is
    /// many-to-one") — and matching on uri lights up every one of them. That drew two rows of
    /// an eleven-track queue green while only one of them advanced.
    ///
    /// Only the queue names a current row, because only the queue has a current *position*.
    /// An album page or a playlist has nothing better than the uri to go on.
    func isPlaying(currentRowId: String?, playingUri: String?) -> Bool {
        if let currentRowId {
            return id == currentRowId
        }
        return track.uri == playingUri
    }
}

/// The tracks of a list as the redesign shows them (`plans/done/redesign-favorites.md`): a
/// sortable `Table` with the columns a page asks for, a click to select, a double-click to play,
/// the track menu on a right click, and a heart and the menu in each row. The playing row is in
/// the accent colour, with an animated waveform for its number.
struct TrackTable: View {
    /// The columns a page may leave out. Titel, Dauer and the row's actions are always there.
    enum Column: Hashable {
        case number
        case album
        case added
    }

    let rows: [TrackTableRow]
    var columns: Set<Column> = [.number]
    /// Where the menu is opened from, which decides what it offers.
    let currentSection: NavigationItem
    /// The page's selection, such as the playlist a row can be removed from.
    var selectionId: String?
    /// Whether the headers sort; a queue keeps its order.
    var sortable = true
    /// The row playing, where the list knows it by position (`TrackTableRow.isPlaying`); the
    /// table scrolls to it on "Scroll to Current Track".
    var currentRowId: String?
    /// Moves the row with this id to sit before the row now at the index, or last past the end;
    /// nil where rows do not move.
    var reorder: (@MainActor @Sendable (_ id: String, _ insertionIndex: Int) -> Void)?
    let play: (TrackTableRow) -> Void

    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaylistService.self) private var playlistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var sortOrder: [KeyPathComparator<TrackTableRow>] = []
    @State private var selection: Set<TrackTableRow.ID> = []
    /// The track the menu's "New Playlist…" was chosen for. Held here: a menu's content cannot
    /// present anything of its own.
    @State private var newPlaylistTrackId: String?

    private var sortedRows: [TrackTableRow] {
        sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onReceive(NotificationCenter.default.publisher(for: .scrollToCurrentTrack)) { _ in
                    guard let currentRowId else { return }
                    withAnimation {
                        proxy.scrollTo(currentRowId, anchor: .center)
                    }
                }
        }
    }

    private var table: some View {
        Table(of: TrackTableRow.self, selection: $selection, sortOrder: sortable ? $sortOrder : .constant([])) {
            TableColumn("table.number", value: \.number) { row in
                NumberCell(row: row, currentRowId: currentRowId)
                    .modifier(cellEnvironment)
            }
            .width(36)
            .defaultVisibility(columns.contains(.number) ? .visible : .hidden)

            TableColumn("table.title", value: \.title) { row in
                TitleCell(row: row, currentRowId: currentRowId)
                    .modifier(cellEnvironment)
            }

            TableColumn("table.album", value: \.album) { row in
                Text(row.album)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .defaultVisibility(columns.contains(.album) ? .visible : .hidden)

            TableColumn("table.added", value: \.addedSortKey) { row in
                if let addedAt = row.addedAt {
                    Text(addedAt, format: .dateTime.day().month(.abbreviated).year())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)
            .defaultVisibility(columns.contains(.added) ? .visible : .hidden)

            TableColumn("table.duration", value: \.durationMs) { row in
                Text(row.track.durationFormatted)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(56)

            TableColumn(Text(verbatim: "")) { row in
                RowActions(row: row, currentSection: currentSection, selectionId: selectionId) {
                    newPlaylistTrackId = row.track.id
                }
                .modifier(cellEnvironment)
            }
            .width(56)
        } rows: {
            // Draggable while the rows are in the list's own order, where an index means a place
            // in it; a page that lets them move says so with `reorder`.
            ForEach(sortedRows) { row in
                TableRow(row)
                    .draggable(row.id)
            }
            .onInsert(of: [.plainText]) { index, providers in
                guard let reorder, isInListOrder, let provider = providers.first else { return }
                _ = provider.loadObject(ofClass: NSString.self) { id, _ in
                    guard let id = id as? String else { return }
                    Task { @MainActor in reorder(id, index) }
                }
            }
        }
        .contextMenu(forSelectionType: TrackTableRow.ID.self) { ids in
            if let row = row(for: ids) {
                RowMenu(row: row, currentSection: currentSection, selectionId: selectionId) {
                    newPlaylistTrackId = row.track.id
                }
                .modifier(cellEnvironment)
            }
        } primaryAction: { ids in
            if let row = row(for: ids) {
                playRow(row)
            }
        }
        // Room under the last row, which the bar floats over: no content margin reaches a table,
        // not the region's nor its own (seen at the end of Favorites), as none reaches a `List`.
        .safeAreaInset(edge: .bottom) {
            Spacer().frame(height: NowPlayingBarView.contentClearance)
        }
        // One check for every row's heart, rather than one per row as it scrolls in; again when
        // the rows change, which a queue does at the same count.
        .task(id: rows.map(\.track.id)) {
            await trackService.ensureFavoriteStatuses(trackIds: rows.map(\.track.id))
        }
        .newPlaylistPrompt(
            isPresented: Binding(get: { newPlaylistTrackId != nil }, set: {
                if !$0 {
                    newPlaylistTrackId = nil
                }
            }),
            trackId: newPlaylistTrackId,
            onAdded: {},
        )
    }

    /// The objects the cells and the menu read, handed to them again: a cell is hosted by the
    /// table's own view, and one built after a later page loaded found no `PlaybackViewModel`
    /// in its environment and trapped (seen 2026-10-21 with Favorites' 323 rows).
    private var cellEnvironment: CellEnvironment {
        CellEnvironment(
            playbackViewModel: playbackViewModel,
            store: store,
            trackService: trackService,
            playlistService: playlistService,
            navigationCoordinator: navigationCoordinator,
        )
    }

    /// Whether the rows stand in the list's own order: unsorted, or sorted by # ascending, which
    /// the header leaves behind once clicked back.
    private var isInListOrder: Bool {
        guard let first = sortOrder.first else { return true }
        return sortOrder.count == 1 && first.keyPath == \TrackTableRow.number && first.order == .forward
    }

    /// The row a click or a menu names: the first of the selection.
    private func row(for ids: Set<TrackTableRow.ID>) -> TrackTableRow? {
        ids.first.flatMap { id in rows.first { $0.id == id } }
    }

    /// A track Spotify will not play starts nothing, and says why, as in every list.
    private func playRow(_ row: TrackTableRow) {
        if let message = row.track.unplayableMessage {
            playbackViewModel.errorMessage = message
        } else {
            play(row)
        }
    }
}

// MARK: - Cells

private struct CellEnvironment: ViewModifier {
    let playbackViewModel: PlaybackViewModel
    let store: AppStore
    let trackService: TrackService
    let playlistService: PlaylistService
    let navigationCoordinator: NavigationCoordinator

    func body(content: Content) -> some View {
        content
            .environment(playbackViewModel)
            .environment(store)
            .environment(trackService)
            .environment(playlistService)
            .environment(navigationCoordinator)
    }
}

/// The row's number, or a waveform moving while its track plays. Each cell follows the playing
/// track itself, so a change of it redraws two cells rather than the whole table.
private struct NumberCell: View {
    let row: TrackTableRow
    let currentRowId: String?

    @Environment(PlaybackViewModel.self) private var playbackViewModel

    var body: some View {
        Group {
            if row.isPlaying(currentRowId: currentRowId, playingUri: playbackViewModel.currentTrackUri) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: playbackViewModel.isPlaying)
            } else {
                Text(row.number, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A 32 pt cover beside the title over the artist; the accent while the track plays, and dimmed
/// once played, or, with the reason as tooltip, where Spotify will not play it.
private struct TitleCell: View {
    let row: TrackTableRow
    let currentRowId: String?

    @Environment(PlaybackViewModel.self) private var playbackViewModel

    private var track: Track {
        row.track
    }

    private var isPlaying: Bool {
        row.isPlaying(currentRowId: currentRowId, playingUri: playbackViewModel.currentTrackUri)
    }

    private static let artworkShape = AnyShape(.rect(cornerRadius: 4))

    var body: some View {
        HStack(spacing: 10) {
            Artwork(images: track.images, size: 32, shape: Self.artworkShape, symbol: "music.note", symbolFont: .caption)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .fontWeight(isPlaying ? .medium : .regular)
                    .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            if let tag = row.tag {
                Text(verbatim: tag)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .rect(cornerRadius: 3))
            }
        }
        .padding(.vertical, 4)
        .opacity(track.isPlayable && !row.isDimmed ? 1 : 0.5)
        .help(ifAny: track.unplayableMessage)
    }
}

/// The heart, red while the track is a favorite, and the track menu.
private struct RowActions: View {
    let row: TrackTableRow
    let currentSection: NavigationItem
    let selectionId: String?
    let newPlaylist: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    var body: some View {
        let isFavorite = store.isFavorite(row.track.id)

        HStack(spacing: 4) {
            Button {
                Task {
                    do {
                        try await trackService.toggleFavorite(trackId: row.track.id)
                    } catch {
                        playbackViewModel.errorMessage = String(localized: "error.update_favorite \(error.localizedDescription)")
                    }
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .named(.favoriteToggle(isFavorited: isFavorite))

            Menu {
                RowMenu(row: row, currentSection: currentSection, selectionId: selectionId, newPlaylist: newPlaylist)
            } label: {
                Label("action.more", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("action.more")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The track menu for a row. "New Playlist…" hands the track to the table, which shows the prompt.
private struct RowMenu: View {
    let row: TrackTableRow
    let currentSection: NavigationItem
    let selectionId: String?
    let newPlaylist: () -> Void

    var body: some View {
        TrackContextMenu(
            track: row.track,
            currentSection: currentSection,
            selectionId: selectionId,
            itemUid: row.itemUid,
            showNewPlaylistDialog: Binding(get: { false }, set: {
                if $0 {
                    newPlaylist()
                }
            }),
        )
    }
}
