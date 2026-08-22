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
        if currentIndex < contextTracks.count {
            return contextTracks[currentIndex]
        }
        return nil
    }

    /// Advances and returns the next uri to play, or nil when the queue ended.
    ///
    /// Track-repeat returns the same track forever; the caller distinguishes
    /// auto-advance from manual next by not consulting this for repeats.
    func advance() -> String? {
        // User queue entries always play next, once.
        if !userQueue.isEmpty {
            let next = userQueue.removeFirst()
            pushHistory()
            return next
        }

        guard !contextTracks.isEmpty else { return nil }

        if repeatMode == .track {
            return contextTracks[currentIndex]
        }

        pushHistory()

        if shuffleEnabled {
            shufflePosition += 1
            if shufflePosition < shuffleOrder.count {
                currentIndex = shuffleOrder[shufflePosition]
                return contextTracks[currentIndex]
            }
            // Context exhausted under shuffle: repeat restarts a fresh shuffle.
            if repeatMode == .context {
                reshuffleKeepingCurrent()
                currentIndex = shuffleOrder[0]
                return contextTracks[currentIndex]
            }
            return nil
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
        guard let previous = history.popLast() else { return nil }

        if !userQueue.isEmpty || shuffleEnabled {
            // Position bookkeeping is best-effort outside plain list order.
            if let idx = contextTracks.firstIndex(of: previous) {
                currentIndex = idx
            }
        } else if let idx = contextTracks.firstIndex(of: previous) {
            currentIndex = idx
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
        let afterCurrent: [String] = if shuffleEnabled {
            shuffleOrder[(shufflePosition + 1)...]
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
