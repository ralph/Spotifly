//
//  PlaybackQueue+Unplayable.swift
//  SwiftLibrespot
//
//  Moving through the queue past tracks Spotify will not play.
//

import Foundation

/// Next, Previous, auto-advance and the fetch-ahead all pass over a track known not to play
/// without loading it. Built on the queue's own moves, so the tracks passed over land in the
/// history the way played ones do.
nonisolated extension PlaybackQueue {
    /// `uri`, or the first track `step` moves the queue on to that `isUnplayable` does not
    /// name. Nil when the queue runs out first, or goes once round it without finding one,
    /// which repeat would otherwise make forever.
    func stepOver(_ isUnplayable: (String) -> Bool, from uri: String?, by step: () -> String?) -> String? {
        var uri = uri
        var stepsLeft = userQueue.count + contextTracks.count
        while let candidate = uri, isUnplayable(candidate) {
            guard stepsLeft > 0 else { return nil }
            stepsLeft -= 1
            uri = step()
        }
        return uri
    }

    /// The first track `step` moves the queue to that `isUnplayable` does not name: Next with
    /// `advance`. A Next that finds none rewinds the context, which puts the queue back.
    func move(by step: () -> String?, skipping isUnplayable: (String) -> Bool) -> String? {
        stepOver(isUnplayable, from: step(), by: step)
    }

    /// Where Previous goes back to: the latest track in the history that `isUnplayable` does
    /// not name. Nil, with the queue left where it is, when none of the history plays. Stepping
    /// back through it would have emptied it and left the queue on its oldest track, while
    /// Previous restarts the one playing.
    func back(skipping isUnplayable: (String) -> Bool) -> String? {
        guard history.contains(where: { !isUnplayable($0) }) else { return nil }
        return move(by: backward, skipping: isUnplayable)
    }

    /// What auto-advance will reach next, without moving there.
    func upcomingPlayable(skipping isUnplayable: (String) -> Bool) -> String? {
        upcoming().first { !isUnplayable($0.uri) }?.uri
    }
}
