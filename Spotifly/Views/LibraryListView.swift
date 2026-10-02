//
//  LibraryListView.swift
//  Spotifly
//
//  The shared body of the Albums, Artists and Playlists sections
//

import SwiftUI

/// What a library section needs of an entity in order to list it.
protocol LibraryEntity: Identifiable, Equatable where ID == String {
    var name: String { get }
    var uri: String { get }
    var images: ImageSet { get }
}

// Isolated conformances, because the entities themselves are main-actor isolated
// under the target's default isolation.
extension Album: @MainActor LibraryEntity {}
extension Artist: @MainActor LibraryEntity {}
extension Playlist: @MainActor LibraryEntity {}

/// A row of a library section shown in its folders: a folder, or an entry, at its depth.
enum LibraryOutlineRow<Entity: LibraryEntity>: Identifiable {
    case folder(uri: String, name: String, depth: Int)
    case entity(Entity, depth: Int)

    var id: String {
        switch self {
        case let .folder(uri, _, _): uri
        case let .entity(entity, _): entity.id
        }
    }

    var depth: Int {
        switch self {
        case let .folder(_, _, depth), let .entity(_, depth): depth
        }
    }
}

/// Everything the three sections show and say differently — the whole of it.
struct LibrarySectionStyle {
    let loadingText: LocalizedStringKey
    let errorTitle: LocalizedStringKey
    let emptyTitle: LocalizedStringKey
    let emptyMessage: LocalizedStringKey
    let emptyGlyph: String
    let placeholderGlyph: String
    let artworkShape: AnyShape
}

/// Albums, artists and playlists are listed identically: a loading, error or empty
/// state until there is something to show, then the ephemeral entity the user
/// navigated to, then their library, then the pagination trigger.
///
/// What actually differs is `LibrarySectionStyle` plus the store collection,
/// coordinator route and service calls the section reaches for — so the section
/// passes those in and keeps nothing else of its own.
struct LibraryListView<Entity: LibraryEntity>: View {
    let items: [Entity]
    let ephemeral: Entity?
    let pagination: PaginationState
    let selectedId: String?
    /// Selects an entry. `recordsHistory` is false only for the automatic first selection.
    let select: @MainActor (String, _ recordsHistory: Bool) -> Void
    let load: @MainActor (_ forceRefresh: Bool) async throws -> Void
    let loadMore: @MainActor () async throws -> Void
    let style: LibrarySectionStyle
    /// The entries in their folders, shown instead of `items` where the section has folders.
    /// `items` still decides what loads.
    var outline: [LibraryOutlineRow<Entity>]?

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    /// The folders open in the list, by uri, one per line: kept across launches, as Spotify's
    /// clients keep theirs. A folder starts closed.
    @AppStorage("openLibraryFolders") private var openFolderList = ""

    /// Whether we have content to show (either the ephemeral entity or the library)
    private var hasContent: Bool {
        ephemeral != nil || !items.isEmpty
    }

    var body: some View {
        // A ZStack, not a Group: a Group hands its `.task` to each branch, so switching
        // between loading and the error started the load again, forever.
        ZStack {
            if pagination.isLoading, !hasContent {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(style.loadingText)
                        .foregroundStyle(.secondary)
                }
            } else if let failure = pagination.failure, !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(style.errorTitle)
                        .font(.headline)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadItems(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .retryingWhenNetworkReturns {
                        await loadItems(forceRefresh: true)
                    }
                }
                .padding()
            } else if !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: style.emptyGlyph)
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(style.emptyTitle)
                        .font(.headline)
                    Text(style.emptyMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Back button when navigated from another section
                        if ephemeral != nil, let backTitle = navigationCoordinator.backNavigationTitle {
                            Button {
                                navigationCoordinator.navigateBackward()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.caption.weight(.semibold))
                                    Text("nav.back_to \(backTitle)")
                                        .font(.subheadline)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 8)
                        }

                        // Ephemeral "Currently Viewing" section
                        if let ephemeral {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("nav.currently_viewing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                row(for: ephemeral)
                            }

                            if !items.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("nav.your_library")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        }

                        ForEach(rows.enumerated(), id: \.element.id) { index, outlineRow in
                            VStack(spacing: 0) {
                                if index > 0 {
                                    Divider()
                                        .padding(.leading, 56 + Self.indent(outlineRow.depth))
                                }

                                switch outlineRow {
                                case let .folder(uri, name, depth):
                                    folderRow(uri: uri, name: name)
                                        .padding(.leading, Self.indent(depth))
                                case let .entity(entity, depth):
                                    row(for: entity)
                                        .padding(.leading, Self.indent(depth))
                                }
                            }
                        }

                        // An outline is loaded whole, and the flat pages behind it are not
                        // what it shows.
                        if outline == nil {
                            LoadMoreRow(pagination: pagination, loadMore: loadMoreItems)
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadItems(forceRefresh: true)
                }
            }
        }
        .task {
            if items.isEmpty, !pagination.isLoading {
                await loadItems()
            }
            selectFirstIfNeeded()
        }
        .onChange(of: items) { _, _ in
            selectFirstIfNeeded()
        }
        // The selection can be inside a closed folder: chosen from the flat list before the
        // outline arrived, or opened from elsewhere. Its folders open, so its row shows.
        .onChange(of: [selectedId] + (outline?.map(\.id) ?? []), initial: true) {
            revealSelection()
        }
    }

    private func row(for entity: Entity) -> some View {
        LibraryRow(
            entity: entity,
            style: style,
            isSelected: selectedId == entity.id,
            onSelect: {
                select(entity.id, true)
            },
        )
    }

    /// What the list shows: the outline, less what closed folders hold, or the flat entries.
    private var rows: [LibraryOutlineRow<Entity>] {
        outline.map(visibleRows(of:)) ?? items.map { .entity($0, depth: 0) }
    }

    private static func indent(_ depth: Int) -> CGFloat {
        CGFloat(depth) * 20
    }

    private var openFolders: Set<String> {
        get { Set(openFolderList.split(separator: "\n").map(String.init)) }
        nonmutating set { openFolderList = newValue.sorted().joined(separator: "\n") }
    }

    /// The outline without what closed folders hold: the rows deeper than a closed folder, up
    /// to the next row at its depth or above.
    private func visibleRows(of outline: [LibraryOutlineRow<Entity>]) -> [LibraryOutlineRow<Entity>] {
        let open = openFolders
        var closedDepth: Int?
        return outline.filter { row in
            if let depth = closedDepth {
                if row.depth > depth {
                    return false
                }
                closedDepth = nil
            }
            if case let .folder(uri, _, depth) = row, !open.contains(uri) {
                closedDepth = depth
            }
            return true
        }
    }

    /// The folders an entry sits in, outermost first: the folders above it at each depth less
    /// than its own.
    static func folders(around entityId: String, in outline: [LibraryOutlineRow<Entity>]) -> [String] {
        var enclosing: [String] = []
        for row in outline {
            enclosing = Array(enclosing.prefix(row.depth))
            switch row {
            case let .folder(uri, _, _):
                enclosing.append(uri)
            case let .entity(entity, _) where entity.id == entityId:
                return enclosing
            case .entity:
                break
            }
        }
        return []
    }

    private func revealSelection() {
        guard let outline, let selectedId else { return }
        let closed = Self.folders(around: selectedId, in: outline).filter { !openFolders.contains($0) }
        guard !closed.isEmpty else { return }
        openFolders.formUnion(closed)
    }

    /// A button, so accessibility can press it: a tap gesture with a button trait announced
    /// itself as one and did nothing when pressed.
    private func folderRow(uri: String, name: String) -> some View {
        let isOpen = openFolders.contains(uri)
        return Button {
            if isOpen {
                openFolders.remove(uri)
            } else {
                openFolders.insert(uri)
            }
        } label: {
            // A folder has no cover; this is the placeholder a playlist without one shows.
            LibraryRowLabel(
                artwork: Artwork(images: .empty, size: 36, shape: style.artworkShape, symbol: "folder", symbolFont: .system(size: 16)),
                name: name,
            ) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? Text("folder.open") : Text("folder.closed"))
    }

    /// The section always shows a detail, so entering it lands on the first entry. The
    /// coordinator is told at this call site that the step is automatic, so it replaces the
    /// route rather than recording a history entry the user never asked for.
    private func selectFirstIfNeeded() {
        guard selectedId == nil else { return }
        // The first row shown, which in an outline is not inside a closed folder.
        let first = rows.lazy.compactMap { row -> Entity? in
            if case let .entity(entity, _) = row {
                entity
            } else {
                nil
            }
        }.first
        guard let first else { return }
        select(first.id, false)
    }

    /// A failure is recorded on `pagination`, where the toolbar's refresh leaves it too.
    private func loadItems(forceRefresh: Bool = false) async {
        try? await load(forceRefresh)
    }

    private func loadMoreItems() async {
        try? await loadMore()
    }
}

private struct LibraryRow<Entity: LibraryEntity>: View {
    let entity: Entity
    let style: LibrarySectionStyle
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(PlaybackViewModel.self) private var playbackViewModel

    @State private var isHovering = false

    /// A button, so accessibility can press it as a click selects it: a tap gesture announced
    /// nothing and could not be pressed. Play, which shows only under the pointer, is one of the
    /// row's actions too.
    var body: some View {
        Button(action: onSelect) {
            LibraryRowLabel(
                artwork: Artwork(
                    images: entity.images,
                    size: 36,
                    shape: style.artworkShape,
                    symbol: style.placeholderGlyph,
                    symbolFont: .system(size: 16),
                    placeholderWhileLoading: true,
                ),
                name: entity.name,
                isSelected: isSelected,
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("action.play"), play)
        .overlay(alignment: .trailing) {
            if isHovering {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(playbackViewModel.isLoading)
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func play() {
        Task {
            await playbackViewModel.play(uriOrUrl: entity.uri)
        }
    }
}

/// What every row of a library section looks like, a folder's and an entry's: a 36-point image,
/// the name, and what follows it.
private struct LibraryRowLabel<Trailing: View>: View {
    let artwork: Artwork
    let name: String
    var isSelected = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            artwork

            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}

extension LibraryRowLabel where Trailing == EmptyView {
    init(artwork: Artwork, name: String, isSelected: Bool = false) {
        self.init(artwork: artwork, name: name, isSelected: isSelected) { EmptyView() }
    }
}
