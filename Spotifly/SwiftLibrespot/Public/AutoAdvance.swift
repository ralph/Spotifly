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
        isUnplayable: (String) -> Bool,
        load: (String) async throws -> Void,
        skipped: (_ uri: String, _ name: String) -> Void,
    ) async -> Outcome {
        let advance = { queue.advance(respectingRepeat: false) }
        // The context's tracks count the one the run starts from, unless the
        // queue has just taken it off the user queue.
        var attemptsLeft = queue.userQueue.count + queue.contextTracks.count
            + (queue.currentProvider == "queue" ? 1 : 0)
        var next: String? = uri
        while let uri = queue.stepOver(isUnplayable, from: next, by: advance) {
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
                next = advance()
            }
        }
        return .queueEnded
    }
}
