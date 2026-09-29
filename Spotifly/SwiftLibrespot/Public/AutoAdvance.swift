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
/// A function over closures, so the rule is tested without a session.
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

    /// Loads `uri`, and goes on past every unavailable track.
    ///
    /// - Parameters:
    ///   - attempts: the most loads to try. Repeat wraps the queue, so a context of nothing
    ///     but unavailable tracks would skip forever; the caller passes how many the queue
    ///     holds. Each skip costs a metadata request or two.
    ///   - load: plays a uri, or throws why it could not.
    ///   - advance: moves the queue on and returns its next uri, or nil at its end.
    ///   - skipped: told the uri and the name of each track before the queue moves past it.
    static func run(
        from uri: String,
        attempts: Int,
        load: (String) async throws -> Void,
        advance: () -> String?,
        skipped: (_ uri: String, _ name: String) -> Void,
    ) async -> Outcome {
        var uri = uri
        var attemptsLeft = attempts
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
                guard let next = advance() else { return .queueEnded }
                uri = next
            }
        }
    }
}
