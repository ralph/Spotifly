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
    private(set) var currentIndex = 0

    /// Tracks queued explicitly ("add to queue"), which play before the
    /// context resumes.
    private(set) var userQueue: [String] = []

    /// Tracks already played, most recent last, for skip-backwards.
    private(set) var history: [String] = []

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

    /// Replaces the whole playing context.
    func setContext(uri: String, tracks: [String], startIndex: Int) {
        contextUri = uri
        contextTracks = tracks
        currentIndex = max(0, min(startIndex, tracks.count - 1))
        history = []
        userQueueCurrent = nil
        reshuffleIfNeeded()
        if shuffleEnabled {
            shufflePosition = shuffleOrder.firstIndex(of: currentIndex) ?? 0
        }
    }

    func enqueue(_ uri: String) {
        userQueue.append(uri)
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

    /// A fresh permutation with nothing pinned, for a context that wrapped.
    /// `reshuffleKeepingCurrent` would put the track that just finished at the
    /// head of the new cycle, so it played twice in a row across the wrap.
    private func reshuffle() {
        shuffleOrder = contextTracks.indices.shuffled()
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
        userQueueCurrent = nil

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
            reshuffle()
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

        guard let previous = history.popLast() else { return nil }

        if let idx = contextTracks.firstIndex(of: previous) {
            currentIndex = idx

            // The shuffle cursor has to come back too. Moving `currentIndex`
            // alone left `shufflePosition` on the track we just stepped away
            // from, so the next advance carried on from there — skipping
            // forward again, or ending the context early.
            if shuffleEnabled, let position = shuffleOrder.firstIndex(of: idx) {
                shufflePosition = position
            }
        }

        return previous
    }

    /// Whether going backwards has anywhere to go besides restarting the
    /// current track.
    var canGoBackward: Bool {
        !history.isEmpty
    }

    private func pushHistory() {
        if let current = currentUri {
            history.append(current)
            if history.count > 50 {
                history.removeFirst()
            }
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

    func recent(limit: Int = 10) -> [(uri: String, provider: String)] {
        history.suffix(limit).reversed().map { ($0, "context") }
    }
}
