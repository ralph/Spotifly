//
//  AutoAdvance.swift
//  SwiftLibrespot
//
//  Going on to the next track when nobody pressed anything.
//

import Foundation

/// How auto-advance goes past the tracks Spotify withholds.
///
/// Nobody pressed anything, so no caller is waiting to be told a load failed, and the rest of
/// the album or playlist is still worth playing. Before this, the first track that failed to
/// load stopped playback there, and nothing said why.
///
/// **Only `trackUnavailable` is skipped.** It is the one error that belongs to the track. A
/// network error, a key that timed out, or a `trackNotFound` from a failed metadata request
/// stops playback instead: skipping those would pass over a playlist's worth of playable tracks
/// while the network blinked.
///
/// It runs on the client's `PlaybackQueue` and two closures, so the rule is tested against a real
/// queue and no session.
nonisolated enum AutoAdvance {
    enum Outcome {
        /// A track is loaded.
        case playing
        /// The queue ran out while skipping.
        case queueEnded
        /// A newer load took over, and it reports for itself.
        case superseded
        /// A load failed in a way that is not skipped, or every track tried was unavailable.
        case stopped(any Error)
    }

    /// Loads `uri`, and goes on through `queue` past every unavailable track.
    ///
    /// Each skip costs the metadata requests. Repeat wraps the queue, so a context of nothing
    /// but unavailable tracks would skip forever: the run tries at most as many tracks as the
    /// queue holds.
    ///
    /// - Parameters:
    ///   - isUnplayable: whether a track is already known to be unavailable, which the queue
    ///     then moves past without loading it, and without a word: its row is greyed out.
    ///   - load: plays a uri, or throws why it could not.
    ///   - skipped: told the uri and the name of each track before the queue moves past it.
    static func run(
        from uri: String,
        in queue: PlaybackQueue,
        isUnplayable: (String) -> Bool = { _ in false },
        load: (String) async throws -> Void,
        skipped: (_ uri: String, _ name: String) -> Void,
    ) async -> Outcome {
        guard var uri = stepOver(isUnplayable, from: uri, in: queue, step: { queue.advance(respectingRepeat: false) }) else {
            return .queueEnded
        }
        // The context's tracks count the one the run starts from, unless the
        // queue has just taken it off the user queue.
        var attemptsLeft = queue.userQueue.count + queue.contextTracks.count
            + (queue.currentProvider == "queue" ? 1 : 0)
        while true {
            do {
                try await load(uri)
                return .playing
            } catch is CancellationError {
                return .superseded
            } catch {
                attemptsLeft -= 1
                guard case let LibrespotError.trackUnavailable(name) = error, attemptsLeft > 0 else {
                    return .stopped(error)
                }
                skipped(uri, name)
                let step = { queue.advance(respectingRepeat: false) }
                guard let next = stepOver(isUnplayable, from: step(), in: queue, step: step) else {
                    return .queueEnded
                }
                uri = next
            }
        }
    }

    /// `uri`, or the first track `step` moves the queue on to that is not known to be
    /// unplayable. Nil when the queue runs out first, or goes once round it without finding
    /// one, which repeat would otherwise make forever.
    ///
    /// Moving on is the queue's own: Next, Previous and auto-advance each pass the step they
    /// take, so the tracks stepped over land in the history the way played ones do.
    static func stepOver(
        _ isUnplayable: (String) -> Bool,
        from uri: String?,
        in queue: PlaybackQueue,
        step: () -> String?,
    ) -> String? {
        var uri = uri
        var stepsLeft = queue.userQueue.count + queue.contextTracks.count
        while let candidate = uri, isUnplayable(candidate) {
            guard stepsLeft > 0 else { return nil }
            stepsLeft -= 1
            uri = step()
        }
        return uri
    }
}
