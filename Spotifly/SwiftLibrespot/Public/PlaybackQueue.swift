//
//  PlaybackQueue.swift
//  SwiftLibrespot
//
//  Client-side playback order: context tracks, user queue, shuffle, repeat.
//
//  The Rust player kept its queue inside Spirc's connect state; without it,
//  ordering lives here. Everything is uri-level — metadata hydrates elsewhere.
//

import Foundation

/// Ordered playback state for the local device.
///
/// Two lists play back to back: a **user queue** of explicitly queued tracks
/// plays first, then the **context** (album/playlist/search results) continues
/// from wherever it is. History remembers what to return to on "previous".
final nonisolated class PlaybackQueue {
    nonisolated enum RepeatMode: Sendable, Equatable {
        case off
        case context
        case track
    }

    private(set) var contextUri = ""
    private(set) var contextTracks: [String] = []
    /// Each context row's uid, beside `contextTracks`: the resolver's, where it gives one, as it
    /// does for a playlist's rows. An album's rows have none, and are named by uri alone.
    private var contextUids: [String?] = []
    private(set) var currentIndex = 0

    /// Where autoplay's rows start among `contextTracks`, once they are lined up after the
    /// context's own (`appendAutoplay`). The context stays the one played, as a phone reports
    /// it while its autoplay plays (2026-10-02), and the rows say `autoplay`.
    private(set) var autoplayStart: Int?

    /// Tracks queued explicitly ("add to queue"), which play before the
    /// context resumes. Each row is named by a uid of its own: `q0`, `q1` and on, as
    /// librespot's `add_to_queue` makes them, so another device can name a queued copy apart
    /// from the same track further on in the context.
    private(set) var queued: [QueueItem] = []

    /// How many tracks have been queued, for the next one's uid.
    private var queuedCount = 0

    /// Where the context tracks already played sit in the context, most recent last, for
    /// skip-backwards. Queued tracks are not kept, as in librespot, which puts "only songs from
    /// our context" in `prev_tracks`. Positions rather than uris, so Previous returns to the
    /// copy that played of a track the context holds twice; `setContext` clears them with the
    /// context they point into.
    private var historyPositions: [Int] = []

    /// The context tracks already played, most recent last.
    var history: [String] {
        historyPositions.map { contextTracks[$0] }
    }

    /// A user-queue track that is playing now. It sits outside the context,
    /// so `currentUri` reports it until playback returns to the context.
    private var userQueueCurrent: QueueItem?

    private(set) var shuffleEnabled = false
    private(set) var repeatMode: RepeatMode = .off

    /// Shuffle visits the context in a random permutation instead of list
    /// order; `shuffleOrder`/`shufflePosition` track where we are in it.
    private var shuffleOrder: [Int] = []
    private var shufflePosition = 0

    // MARK: - Loading

    /// Where a context starts, from what the caller named: a position in it, a track, or
    /// both.
    ///
    /// A double-click names both, and the view's list is not the resolved context, so the
    /// index alone can name another track (`plans/done/clicked-row-plays-another-track.md`).
    /// So the track decides, and the index says which copy of it: the one nearest the index.
    /// A track the context does not name still has to be the one that plays, so it goes in at
    /// the index, where what follows is what followed its row, or in front without one. An
    /// index alone is clamped to the context, as it always was.
    ///
    /// A uid, where the sender gave one and the context lists it, names the row itself and comes
    /// first: a relinked track is handed over under another id than the context lists it by
    /// (`plans/done/handover-of-a-relinked-track-starts-at-the-top.md`).
    ///
    /// - Returns: the tracks to play, the named track put in when it was missing, their uids
    ///   beside them, with none for a track put in, and the index to start at.
    static func start(
        in tracks: [String],
        index: Int?,
        uri: String?,
        uid: String? = nil,
        uids: [String?] = [],
    ) -> (tracks: [String], uids: [String?], index: Int) {
        let uids = aligned(uids, to: tracks)
        if let uid, let row = uids.firstIndex(of: uid) {
            return (tracks, uids, row)
        }
        let target = min(max(index ?? 0, 0), max(tracks.count - 1, 0))
        guard let uri else { return (tracks, uids, target) }
        if let nearest = tracks.nearestIndex(to: target, where: { $0 == uri }) {
            return (tracks, uids, nearest)
        }
        var tracks = tracks, inserted = uids
        tracks.insert(uri, at: target)
        inserted.insert(nil, at: target)
        return (tracks, inserted, target)
    }

    /// Each row's uid from `listed`, another list of the context's rows: the n-th copy of a track
    /// takes the n-th uid listed for it. Matched by track, not by place, as a row put in at the
    /// start, or a list of another length, would move every uid after it onto another row.
    static func rowUids(_ listed: [(uri: String, uid: String)], of tracks: [String]) -> [String?] {
        var left = Dictionary(grouping: listed) { $0.uri }.mapValues { $0.map(\.uid)[...] }
        return tracks.map { left[$0]?.popFirst() }
    }

    /// `uids` as long as `tracks`: cut, or padded with none.
    private static func aligned(_ uids: [String?], to tracks: [String]) -> [String?] {
        guard uids.count != tracks.count else { return uids }
        return Array(uids.prefix(tracks.count)) + Array(repeating: nil, count: max(0, tracks.count - uids.count))
    }

    /// Where a context starts when a queued track plays first, from the row the context goes on
    /// with after it, as a handover names it while a queued track plays.
    ///
    /// On the row before that, with the track to play as queued: Next into a queued track leaves
    /// `currentIndex` there too (librespot's `finish_transfer`). Before the first row there is no
    /// row to stand on, so the track goes in front of it, as a context row. Nil for a uid the
    /// context does not list, which leaves the track to `start`.
    static func start(
        in tracks: [String],
        queued uri: String,
        resumingAt uid: String,
        uids: [String?],
    ) -> (tracks: [String], uids: [String?], index: Int, queued: String?)? {
        let uids = aligned(uids, to: tracks)
        guard let row = uids.firstIndex(of: uid) else { return nil }
        guard row > 0 else { return ([uri] + tracks, [nil] + uids, 0, nil) }
        return (tracks, uids, row - 1, uri)
    }

    /// The row a jump names: the one with its uid, where a row has that uid and that track, and
    /// otherwise the copy of the track nearest `position`.
    private static func row(of uri: String, uid: String?, nearest position: Int, in rows: [QueueItem]) -> Int? {
        rows.firstIndex { uid != nil && $0.uid == uid && $0.uri == uri }
            ?? rows.nearestIndex(to: position) { $0.uri == uri }
    }

    /// Starts the context over at `startIndex`, with the rows it has: the end of it, played
    /// through with nothing to repeat. Autoplay's rows go, as the context's own come round again.
    func rewind(to startIndex: Int) {
        setContext(uri: contextUri, tracks: Array(contextTracks.prefix(ownCount)), uids: Array(contextUids.prefix(ownCount)), startIndex: startIndex)
    }

    /// Replaces the whole playing context, with its rows' uids where it has them.
    func setContext(uri: String, tracks: [String], uids: [String?] = [], startIndex: Int) {
        contextUri = uri
        contextTracks = tracks
        contextUids = Self.aligned(uids, to: tracks)
        autoplayStart = nil
        autoplayAsked = false
        currentIndex = max(0, min(startIndex, tracks.count - 1))
        historyPositions = []
        userQueueCurrent = nil
        reshuffleIfNeeded()
        if shuffleEnabled {
            shufflePosition = shuffleOrder.firstIndex(of: currentIndex) ?? 0
        }
    }

    /// Gives the rows of the context `uri` the uids `listed` names, where none of its rows has
    /// one yet: an album's, which the context resolver leaves out. Nothing for another context,
    /// which has replaced it since the uids were asked for.
    ///
    /// - Returns: whether any row has a uid now.
    func adoptRowUids(_ listed: [(uri: String, uid: String)], ofContext uri: String) -> Bool {
        let own = ownCount
        guard uri == contextUri, !contextUids.prefix(own).contains(where: { $0 != nil }) else { return false }
        contextUids = Self.rowUids(listed, of: Array(contextTracks.prefix(own))) + contextUids.dropFirst(own)
        return contextUids.prefix(own).contains { $0 != nil }
    }

    func enqueue(_ uri: String) {
        queued.append(queuedTrack(uri))
    }

    /// The next queued track's row, under a uid of its own.
    private func queuedTrack(_ uri: String) -> QueueItem {
        defer { queuedCount += 1 }
        return QueueItem(uri: uri, provider: "queue", uid: "q\(queuedCount)")
    }

    /// Plays a track as queued, now: after the current context track, which goes into the
    /// history, and before the context goes on. What a handover that arrives while a queued
    /// track plays leaves.
    func playQueued(_ uri: String) {
        queued.insert(queuedTrack(uri), at: 0)
        _ = advance()
    }

    /// Replaces the explicitly queued tracks wholesale, as a handover does:
    /// the sender's queue is the queue now, and whatever was left here from
    /// before the playback went away has played elsewhere since. A remote
    /// `set_queue` does the same with the queue another device has edited.
    ///
    /// The rows are named afresh, as librespot's `set_next_tracks` names them: "technically we
    /// could preserve the queue-uid here, but it seems to work without that".
    func replaceUserQueue(with uris: [String]) {
        queued = uris.map(queuedTrack)
    }

    // MARK: - Options

    func setShuffle(_ enabled: Bool) {
        guard enabled != shuffleEnabled else { return }
        shuffleEnabled = enabled
        if enabled {
            reshuffleKeepingCurrent()
        }
    }

    /// Repeat plays the context's own rows again, so autoplay's go while one of those plays.
    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        if mode != .off {
            dropAutoplay()
        }
    }

    // MARK: - Autoplay

    /// Where the context's own rows end; autoplay's come after them. A round of the context,
    /// for repeat and shuffle, is its own rows.
    private var ownCount: Int {
        autoplayStart ?? contextTracks.count
    }

    /// Whether autoplay was asked for this context, answered or not: once per context, and
    /// again after its rows were taken away.
    private(set) var autoplayAsked = false

    /// The station autoplay's rows came from, `spotify:station:…`, where it is known: other
    /// devices are told it with each of them, as librespot tells them and a phone's rows carry
    /// it.
    private(set) var autoplayContextUri: String?

    func markAutoplayAsked() {
        autoplayAsked = true
    }

    /// How many of the context's tracks seed a station, as go-librespot's
    /// `maxAutoplaySeedTracks`.
    static let autoplaySeedLimit = 50

    /// The context's own tracks, without autoplay's.
    var ownTracks: ArraySlice<String> {
        contextTracks.prefix(ownCount)
    }

    /// The tracks to seed a station with: the context's own, its last `autoplaySeedLimit`.
    var autoplaySeed: [String] {
        Array(ownTracks.suffix(Self.autoplaySeedLimit))
    }

    /// Lines up autoplay's `tracks` after the context's own rows, in their order also when
    /// shuffled: a station goes on from where the context ended.
    func appendAutoplay(_ tracks: [String], uids: [String?], from station: String? = nil) {
        guard autoplayStart == nil, !tracks.isEmpty else { return }
        let start = contextTracks.count
        contextTracks += tracks
        contextUids += Self.aligned(uids, to: tracks)
        autoplayStart = start
        autoplayContextUri = station
        if shuffleEnabled {
            shuffleOrder += start ..< contextTracks.count
        }
    }

    /// Goes on with autoplay's rows after the context's row standing, as another device's autoplay
    /// is taken over: the first of them plays, and that row goes into the history for Previous.
    func playAutoplay(_ tracks: [String], uids: [String?], from station: String? = nil) {
        guard autoplayStart == nil, !tracks.isEmpty else { return }
        pushHistory()
        appendAutoplay(tracks, uids: uids, from: station)
        currentIndex = ownCount
        if shuffleEnabled {
            shuffleOrder = Array(currentIndex ..< contextTracks.count)
            shufflePosition = 0
        }
        autoplayAsked = true
    }

    /// Takes autoplay's rows away again, unless one of them plays, and lets it be asked for
    /// again.
    func dropAutoplay() {
        guard !isAutoplayRow(currentIndex) else { return }
        removeAutoplayRows()
    }

    private func removeAutoplayRows() {
        autoplayAsked = false
        guard let start = autoplayStart else { return }
        contextTracks.removeSubrange(start...)
        contextUids.removeSubrange(start...)
        shuffleOrder.removeAll { $0 >= start }
        historyPositions.removeAll { $0 >= start }
        autoplayStart = nil
        autoplayContextUri = nil
    }

    private func isAutoplayRow(_ index: Int) -> Bool {
        autoplayStart.map { index >= $0 } ?? false
    }

    private func reshuffleIfNeeded() {
        if shuffleEnabled {
            reshuffleKeepingCurrent()
        }
    }

    /// A fresh permutation for a context that wrapped, not opening on the
    /// track that just finished.
    ///
    /// `reshuffleKeepingCurrent` pinned that track to the head, so it always
    /// played twice in a row across the wrap. An unpinned shuffle only does it
    /// sometimes, which is worse to reason about and just as audible — so the
    /// one ordering a listener actually notices is excluded outright.
    private func reshuffle(avoiding lastIndex: Int) {
        shuffleOrder = contextTracks.indices.shuffled()
        if shuffleOrder.count > 1, shuffleOrder[0] == lastIndex {
            shuffleOrder.swapAt(0, Int.random(in: 1 ..< shuffleOrder.count))
        }
        shufflePosition = 0
    }

    /// Builds a fresh random visit order that still starts at the current track. Autoplay's
    /// rows stay after the context's own, in their order; while one of them plays, the rest of
    /// them is what is left.
    private func reshuffleKeepingCurrent() {
        guard !contextTracks.isEmpty else {
            shuffleOrder = []
            return
        }
        if isAutoplayRow(currentIndex) {
            shuffleOrder = Array(currentIndex ..< contextTracks.count)
        } else {
            var others = Array(contextTracks.indices.prefix(ownCount).filter { $0 != currentIndex })
            others.shuffle()
            shuffleOrder = [currentIndex] + others + contextTracks.indices.dropFirst(ownCount)
        }
        shufflePosition = 0
    }

    // MARK: - Traversal

    /// The current track uri, or nil when nothing is loaded.
    var currentUri: String? {
        current?.uri
    }

    /// Advances and returns the next uri to play, or nil when the queue ended.
    ///
    /// - Parameter respectingRepeat: auto-advance under repeat-one replays the
    ///   current track; a manual skip must move regardless, so callers pass
    ///   false there.
    func advance(respectingRepeat: Bool = true) -> String? {
        // User queue entries always play next, once.
        if !queued.isEmpty {
            let next = queued.removeFirst()
            pushHistory()
            userQueueCurrent = next
            return next.uri
        }
        // Back to the context once this move is made, so the push below still sees a queued
        // track playing and records nothing for it.
        defer { userQueueCurrent = nil }

        guard !contextTracks.isEmpty else { return nil }

        if respectingRepeat, repeatMode == .track {
            return contextTracks[currentIndex]
        }

        pushHistory()

        if shuffleEnabled {
            let next = shufflePosition + 1
            if next < shuffleOrder.count {
                shufflePosition = next
                currentIndex = shuffleOrder[shufflePosition]
                return contextTracks[currentIndex]
            }

            // Exhausted. The position stays on the last track rather than
            // stepping past the end — `upcoming()` slices the order from
            // `shufflePosition + 1`, and walking off it trapped the process.
            // A new round is the context's own rows, without autoplay's.
            guard repeatMode == .context, ownCount > 0 else { return nil }
            removeAutoplayRows()
            reshuffle(avoiding: currentIndex)
            currentIndex = shuffleOrder[0]
            return contextTracks[currentIndex]
        }

        if currentIndex + 1 < contextTracks.count {
            currentIndex += 1
            return contextTracks[currentIndex]
        }

        if repeatMode == .context, ownCount > 0 {
            removeAutoplayRows()
            currentIndex = 0
            return contextTracks[0]
        }

        return nil
    }

    /// Steps backwards through history. Returns nil when there is nowhere to
    /// go — callers then decide whether restarting the track counts as previous.
    func backward() -> String? {
        // Leaving an explicitly-queued track first: the history entry pushed
        // when the override started names the context track to return to.
        userQueueCurrent = nil

        guard let previous = historyPositions.popLast() else { return nil }
        currentIndex = previous

        // The shuffle cursor has to come back too. Moving `currentIndex`
        // alone left `shufflePosition` on the track we just stepped away
        // from, so the next advance carried on from there — skipping
        // forward again, or ending the context early.
        if shuffleEnabled, let position = shuffleOrder.firstIndex(of: previous) {
            shufflePosition = position
        }

        return contextTracks[previous]
    }

    /// Moves to a track `upcoming(rounds: .asPlayed)` lists, the next round under
    /// repeat included, the way pressing Next would get there: context tracks
    /// passed over go into the history, as librespot's
    /// `skip_next` puts them in `prev_tracks`. Queued tracks ahead of a queued
    /// target are dropped. A context target leaves the queued tracks where
    /// they are, to play after it, as go-librespot's does.
    ///
    /// A `uid` names the row itself, where the list has it. Otherwise `uri` decides and
    /// `position` picks the copy, as in `start(in:index:uri:)`; without one, the first copy
    /// ahead.
    ///
    /// - Returns: the uri to play, or nil when the list has no such track.
    func skip(toUpcoming position: Int?, uri: String, uid: String? = nil) -> String? {
        guard let row = Self.row(of: uri, uid: uid, nearest: position ?? 0, in: upcoming(rounds: .asPlayed)) else {
            return nil
        }

        if row < queued.count {
            queued.removeFirst(row)
            return advance(respectingRepeat: false)
        }

        let waiting = queued
        queued = []
        defer { queued = waiting }
        var played: String?
        for _ in 0 ... row - waiting.count {
            played = advance(respectingRepeat: false)
        }
        return played
    }

    /// Steps back to a track `recent()` lists, as pressing Previous that many
    /// times would. Found as `skip(toUpcoming:uri:uid:)` finds its track.
    ///
    /// - Returns: the uri to play, or nil when the list has no such track.
    func stepBack(toRecent index: Int, uri: String, uid: String? = nil) -> String? {
        let rows = recent()
        guard let row = Self.row(of: uri, uid: uid, nearest: index, in: rows) else { return nil }

        var played: String?
        for _ in row ..< rows.count {
            played = backward()
        }
        return played
    }

    /// Where the current track sits in the context, or nil while a queued
    /// track plays — it is not part of the context at all.
    var contextPosition: Int? {
        guard userQueueCurrent == nil, currentIndex < contextTracks.count else { return nil }
        return currentIndex
    }

    /// Where other devices are told the current track sits in the context: nowhere while a
    /// queued or an autoplay track plays, as librespot clears `player.index` for both. An autoplay
    /// row's position lies past the context's end, and a phone that took over an autoplay track
    /// told so made it a queued one, with the context's last track again after it (2026-10-02).
    var reportedIndex: Int? {
        contextPosition.flatMap { isAutoplayRow($0) ? nil : $0 }
    }

    /// Where the current track came from, in the cluster's vocabulary.
    var currentProvider: String {
        current?.provider ?? "context"
    }

    /// Whether going backwards has anywhere to go besides restarting the
    /// current track.
    var canGoBackward: Bool {
        !historyPositions.isEmpty
    }

    /// Records the context track playing now. Nothing while a queued track plays: it is not
    /// kept, and the context track it interrupted went in when it started.
    private func pushHistory() {
        guard let position = contextPosition else { return }
        historyPositions.append(position)
        if historyPositions.count > 50 {
            historyPositions.removeFirst()
        }
    }

    // MARK: - Snapshots

    /// The uri of the row librespot and the web player put where the context starts over.
    static let delimiterUri = "spotify:delimiter"

    /// How many rounds of the context `upcoming(limit:rounds:)` lists.
    enum Rounds {
        /// The rest of this one. The queue view lists that much, as the web player's own queue
        /// panel does under repeat (measured 2026-10-01), and the bar counts its rows.
        case one
        /// Under repeat, the context again from its start until `limit` is reached: the order
        /// auto-advance plays. Shuffled, the next round's order is drawn only when it starts,
        /// so none is listed.
        case asPlayed
        /// As played, with a hidden `spotify:delimiter` row, uid `delimiter<n>`, where the
        /// context starts over, as librespot's `fill_up_next_tracks` tells other devices.
        case asReported
    }

    /// The upcoming tracks: user queue first, then the rest of the context, and as many more
    /// rounds of it as `rounds` says.
    func upcoming(limit: Int = 50, rounds: Rounds = .one) -> [QueueItem] {
        var result = Array(queued.prefix(limit))
        result.append(contentsOf: contextIndicesAfterCurrent(limit: limit).map(contextRow))
        if rounds != .one, repeatMode == .context, !shuffleEnabled, ownCount > 0 {
            var round = 0
            while result.count < limit {
                if rounds == .asReported {
                    result.append(QueueItem(uri: Self.delimiterUri, provider: "context", uid: "delimiter\(round)", hidden: true))
                }
                round += 1
                result.append(contentsOf: contextTracks.indices.prefix(ownCount).prefix(limit - result.count).map(contextRow))
            }
        }
        return Array(result.prefix(limit))
    }

    /// The context's rows after the current one, in play order, this round.
    private func contextIndicesAfterCurrent(limit: Int) -> [Int] {
        // `dropFirst` rather than a range slice: it clamps, where
        // `shuffleOrder[(shufflePosition + 1)...]` traps the moment the
        // position sits on the last entry.
        if shuffleEnabled {
            shuffleOrder.dropFirst(shufflePosition + 1)
                .prefix(limit)
                .filter(contextTracks.indices.contains)
        } else {
            Array(contextTracks.indices.dropFirst(currentIndex + 1).prefix(limit))
        }
    }

    /// The context row the session stands on: the current track's, or while a queued track
    /// plays, the row the context goes on with after it, which a handover names as the
    /// session's `current_uid`. Nil past the context's end.
    var sessionRow: QueueItem? {
        userQueueCurrent == nil ? current : contextIndicesAfterCurrent(limit: 1).first.map(contextRow)
    }

    /// How many played tracks `recent()` lists.
    static let recentLimit = 10

    /// The last `limit` tracks played, in play order: the most recent last,
    /// beside the current track.
    ///
    /// Both readers want that order: Connect's `prev_tracks`, as librespot
    /// keeps it, and the queue view, which lists these above the current
    /// track. See `plans/done/queue-history-listed-newest-first.md`.
    func recent(limit: Int = PlaybackQueue.recentLimit) -> [QueueItem] {
        historyPositions.suffix(limit).map(contextRow)
    }

    /// The row at `index` in the context, as Connect lists it.
    private func contextRow(_ index: Int) -> QueueItem {
        QueueItem(uri: contextTracks[index], provider: isAutoplayRow(index) ? "autoplay" : "context", uid: contextUids[index])
    }

    /// The current track's row, as the queue lists it.
    var current: QueueItem? {
        userQueueCurrent ?? contextPosition.map(contextRow)
    }
}
