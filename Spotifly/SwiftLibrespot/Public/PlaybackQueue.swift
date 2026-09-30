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
    /// What the context calls itself, from the resolver: for Liked Songs, which the store
    /// has under no name, "Lieblingssongs". Nil for a bare list of tracks.
    private(set) var contextName: String?
    private(set) var contextTracks: [String] = []
    private(set) var currentIndex = 0

    /// Tracks queued explicitly ("add to queue"), which play before the
    /// context resumes.
    private(set) var userQueue: [String] = []

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
    private var userQueueCurrent: String?

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
    /// - Returns: the tracks to play, the named track put in when it was missing, and the
    ///   index to start at.
    static func start(in tracks: [String], index: Int?, uri: String?) -> (tracks: [String], index: Int) {
        let target = min(max(index ?? 0, 0), max(tracks.count - 1, 0))
        guard let uri else { return (tracks, target) }
        if let nearest = tracks.nearestIndex(to: target, where: { $0 == uri }) {
            return (tracks, nearest)
        }
        var tracks = tracks
        tracks.insert(uri, at: target)
        return (tracks, target)
    }

    /// Replaces the whole playing context.
    func setContext(uri: String, tracks: [String], startIndex: Int, name: String? = nil) {
        contextUri = uri
        contextName = name
        contextTracks = tracks
        currentIndex = max(0, min(startIndex, tracks.count - 1))
        historyPositions = []
        userQueueCurrent = nil
        reshuffleIfNeeded()
        if shuffleEnabled {
            shufflePosition = shuffleOrder.firstIndex(of: currentIndex) ?? 0
        }
    }

    func enqueue(_ uri: String) {
        userQueue.append(uri)
    }

    /// Replaces the explicitly queued tracks wholesale, as a handover does:
    /// the sender's queue is the queue now, and whatever was left here from
    /// before the playback went away has played elsewhere since. A remote
    /// `set_queue` does the same with the queue another device has edited.
    func replaceUserQueue(with uris: [String]) {
        userQueue = uris
    }

    // MARK: - Options

    func setShuffle(_ enabled: Bool) {
        guard enabled != shuffleEnabled else { return }
        shuffleEnabled = enabled
        if enabled {
            reshuffleKeepingCurrent()
        }
    }

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
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

    /// Builds a fresh random visit order that still starts at the current track.
    private func reshuffleKeepingCurrent() {
        guard !contextTracks.isEmpty else {
            shuffleOrder = []
            return
        }
        var others = Array(contextTracks.indices.filter { $0 != currentIndex })
        others.shuffle()
        shuffleOrder = [currentIndex] + others
        shufflePosition = 0
    }

    // MARK: - Traversal

    /// The current track uri, or nil when nothing is loaded.
    var currentUri: String? {
        userQueueCurrent ?? (currentIndex < contextTracks.count ? contextTracks[currentIndex] : nil)
    }

    /// Advances and returns the next uri to play, or nil when the queue ended.
    ///
    /// - Parameter respectingRepeat: auto-advance under repeat-one replays the
    ///   current track; a manual skip must move regardless, so callers pass
    ///   false there.
    func advance(respectingRepeat: Bool = true) -> String? {
        // User queue entries always play next, once.
        if !userQueue.isEmpty {
            let next = userQueue.removeFirst()
            pushHistory()
            userQueueCurrent = next
            return next
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
            guard repeatMode == .context else { return nil }
            reshuffle(avoiding: currentIndex)
            currentIndex = shuffleOrder[0]
            return contextTracks[currentIndex]
        }

        if currentIndex + 1 < contextTracks.count {
            currentIndex += 1
            return contextTracks[currentIndex]
        }

        if repeatMode == .context {
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

    /// Moves to a track `upcoming()` lists, the way pressing Next would get
    /// there: context tracks passed over go into the history, as librespot's
    /// `skip_next` puts them in `prev_tracks`. Queued tracks ahead of a queued
    /// target are dropped. A context target leaves the queued tracks where
    /// they are, to play after it, as go-librespot's does.
    ///
    /// `uri` decides and `position` picks the copy, as in `start(in:index:uri:)`;
    /// without one, the first copy ahead.
    ///
    /// - Returns: the uri to play, or nil when the list has no such track.
    func skip(toUpcoming position: Int?, uri: String) -> String? {
        guard let row = upcoming().map(\.uri).nearestIndex(to: position ?? 0, where: { $0 == uri }) else {
            return nil
        }

        if row < userQueue.count {
            userQueue.removeFirst(row)
            return advance(respectingRepeat: false)
        }

        let queued = userQueue
        userQueue = []
        defer { userQueue = queued }
        var played: String?
        for _ in 0 ... row - queued.count {
            played = advance(respectingRepeat: false)
        }
        return played
    }

    /// Steps back to a track `recent()` lists, as pressing Previous that many
    /// times would. Found as `skip(toUpcoming:uri:)` finds its track.
    ///
    /// - Returns: the uri to play, or nil when the list has no such track.
    func stepBack(toRecent index: Int, uri: String) -> String? {
        let rows = recent().map(\.uri)
        guard let row = rows.nearestIndex(to: index, where: { $0 == uri }) else { return nil }

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

    /// Where the current track came from, in the cluster's vocabulary.
    var currentProvider: String {
        userQueueCurrent == nil ? "context" : "queue"
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

    /// The upcoming tracks: user queue first, then remaining context.
    func upcoming(limit: Int = 50) -> [(uri: String, provider: String)] {
        var result = userQueue.map { ($0, "queue") }
        // `dropFirst` rather than a range slice: it clamps, where
        // `shuffleOrder[(shufflePosition + 1)...]` traps the moment the
        // position sits on the last entry.
        let afterCurrent: [String] = if shuffleEnabled {
            shuffleOrder.dropFirst(shufflePosition + 1)
                .prefix(limit)
                .compactMap { contextTracks.indices.contains($0) ? contextTracks[$0] : nil }
        } else {
            contextTracks.dropFirst(currentIndex + 1).prefix(limit).map(\.self)
        }

        result.append(contentsOf: afterCurrent.map { ($0, "context") })
        return Array(result.prefix(limit))
    }

    /// How many played tracks `recent()` lists.
    static let recentLimit = 10

    /// The last `limit` tracks played, in play order: the most recent last,
    /// beside the current track.
    ///
    /// Both readers want that order: Connect's `prev_tracks`, as librespot
    /// keeps it, and the queue view, which lists these above the current
    /// track. See `plans/done/queue-history-listed-newest-first.md`.
    func recent(limit: Int = PlaybackQueue.recentLimit) -> [(uri: String, provider: String)] {
        history.suffix(limit).map { ($0, "context") }
    }
}
