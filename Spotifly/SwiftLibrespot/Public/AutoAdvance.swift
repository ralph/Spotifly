//
//  AutoAdvance.swift
//  SwiftLibrespot
//
//  Going on past a track Spotify withholds, at the end of a track or on a skip.
//

import Foundation

/// How auto-advance, and a skip by hand, go past the tracks Spotify withholds.
///
/// The rest of the album or playlist is still worth playing, however the track that cannot play
/// came up: at the end of the one before, on a Next, a Previous or a jump in the queue, or at the
/// start of a play or a handover. librespot goes on past it the same way (`handle_next` on
/// `PlayerEvent::Unavailable`). Before, the first such track stopped playback, except at the end
/// of a track.
///
/// **Only `trackUnavailable` is skipped.** It is the one error that belongs to the track. A
/// network error, a key that timed out, or a metadata request that failed stops playback
/// instead: skipping those would pass over a playlist's worth of playable tracks while the
/// network blinked.
///
/// It runs on the client's `PlaybackQueue` and two closures, so the rule is tested against a real
/// queue and no session.
nonisolated enum AutoAdvance {
    /// Which way a run goes on past a track that cannot play.
    enum Direction {
        /// The end of a track, Next, and a jump to a next track.
        case forward
        /// Previous, and a jump to a previous track: to the latest track in the history not
        /// known to be unplayable.
        case backward
    }

    enum Outcome {
        /// A track is loaded.
        case playing
        /// The queue ran out while skipping. Forward, that is its end. Backward, the history has
        /// nothing left that plays, and the queue stays on the track that did not.
        case queueEnded
        /// A newer load took over, and it reports for itself.
        case superseded
        /// A load failed in a way that is not skipped, or every track tried was unavailable.
        case stopped(any Error)
    }

    /// Loads `uri`, and goes on through `queue` in `direction` past every unavailable track.
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
        going direction: Direction = .forward,
        isUnplayable: (String) -> Bool,
        load: (String) async throws -> Void,
        skipped: (_ uri: String, _ name: String) -> Void,
    ) async -> Outcome {
        func step() -> String? {
            switch direction {
            case .forward: queue.advance(respectingRepeat: false)
            case .backward: queue.back(skipping: isUnplayable)
            }
        }
        // The context's tracks count the one the run starts from, unless the
        // queue has just taken it off the user queue.
        var attemptsLeft = queue.queued.count + queue.contextTracks.count
            + (queue.currentProvider == "queue" ? 1 : 0)
        var next: String? = uri
        while let uri = queue.stepOver(isUnplayable, from: next, by: step) {
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
                next = step()
            }
        }
        return .queueEnded
    }
}
