//
//  QueueBootstrapTests.swift
//  SpotiflyTests
//
//  What the bootstrap is allowed to conclude from a cluster snapshot.
//

import Foundation
@testable import Spotifly
import Testing

/// A bootstrap that finds no playback must leave the queue alone.
///
/// The source changed — this used to read `/me/player` and `/me/player/queue`, which answered
/// 204 while no device was active — but the hazard did not: an answer meaning "I have nothing
/// to tell you" is shaped exactly like one meaning "nothing is queued", and applying the second
/// when you were handed the first is what emptied the queue on every wake from sleep. See
/// `plans/wake-from-sleep-loses-queue-and-resume.md`.
///
/// Now the two forms are a **nil** snapshot, meaning no cluster update has arrived, and a
/// snapshot with nothing playing and nothing pending.
@MainActor
struct QueueBootstrapTests {
    private func item(_ id: String, provider: String = "context") -> QueueItem {
        QueueItem(
            id: "spotify:track:\(id)",
            uri: "spotify:track:\(id)",
            name: "Track \(id)",
            artistName: "Artist",
            imageURLString: "",
            durationMs: 1000,
            albumId: nil,
            artistId: nil,
            externalUrl: nil,
            provider: provider,
        )
    }

    /// The cold-start case: nothing has been pushed yet, which is not the same as being told
    /// that nothing is playing.
    @Test func `no snapshot at all carries no playback`() {
        #expect(QueueService.queueUpdate(from: nil) == nil)
    }

    @Test func `an empty snapshot carries no playback`() {
        let empty = QueueState(currentTrack: nil, nextTracks: [], previousTracks: [])

        #expect(QueueService.queueUpdate(from: empty) == nil)
    }

    /// History alone is exactly what a wiped queue looks like, so it is not enough to apply.
    @Test func `previous tracks alone carry no playback`() {
        let snapshot = QueueState(
            currentTrack: nil,
            nextTracks: [],
            previousTracks: [item("played")],
        )

        #expect(QueueService.queueUpdate(from: snapshot) == nil)
    }

    @Test func `a current track alone carries playback`() throws {
        let snapshot = QueueState(currentTrack: item("playing"), nextTracks: [], previousTracks: [])
        let update = try #require(QueueService.queueUpdate(from: snapshot))

        #expect(update.current?.trackId == "playing")
        #expect(update.next.isEmpty)
    }

    @Test func `pending tracks alone carry playback`() throws {
        // Nothing is playing but the cluster still knows what is queued — that is an answer,
        // not the absence of one, so it may be applied.
        let snapshot = QueueState(currentTrack: nil, nextTracks: [item("pending")], previousTracks: [])
        let update = try #require(QueueService.queueUpdate(from: snapshot))

        #expect(update.current == nil)
        #expect(update.next.map(\.trackId) == ["pending"])
    }

    /// **Previous tracks survive the move.** `/me/player/queue` returned none at all, so the
    /// Web API bootstrap had to pass `previous: nil` and leave history to be refilled by
    /// something else. The cluster carries it.
    @Test func `history comes back with the rest`() throws {
        let snapshot = QueueState(
            currentTrack: item("playing"),
            nextTracks: [item("pending")],
            previousTracks: [item("played")],
        )
        let update = try #require(QueueService.queueUpdate(from: snapshot))

        #expect(update.previous.map(\.trackId) == ["played"])
        #expect(update.current?.trackId == "playing")
        #expect(update.next.map(\.trackId) == ["pending"])
    }

    /// The cluster can name things this app has no row for, and a queue is not a reason to
    /// invent one.
    @Test func `items that are not tracks are dropped`() throws {
        let episode = QueueItem(
            id: "spotify:episode:e1",
            uri: "spotify:episode:e1",
            name: "Episode",
            artistName: "",
            imageURLString: "",
            durationMs: 1000,
            albumId: nil,
            artistId: nil,
            externalUrl: nil,
            provider: "context",
        )
        let snapshot = QueueState(
            currentTrack: item("playing"),
            nextTracks: [episode, item("pending")],
            previousTracks: [],
        )
        let update = try #require(QueueService.queueUpdate(from: snapshot))

        #expect(update.next.map(\.trackId) == ["pending"])
    }

    /// The provider rides along, because the queue view distinguishes a track queued by hand
    /// from one the context supplied.
    @Test func `the provider survives the conversion`() throws {
        let snapshot = QueueState(
            currentTrack: nil,
            nextTracks: [item("queued", provider: "queue")],
            previousTracks: [],
        )
        let update = try #require(QueueService.queueUpdate(from: snapshot))

        #expect(update.next.first?.provider == .queue)
    }

    @Test func `a paused local queue is exactly what an empty snapshot would destroy`() {
        // The state this bug was found in: history, a current track, and pending tracks.
        let store = AppStore()
        store.setQueue(
            previous: [QueueEntry(trackId: "played", provider: .context)],
            current: QueueEntry(trackId: "playing", provider: .context),
            next: [QueueEntry(trackId: "pending", provider: .context)],
        )

        // Applying an empty update keeps the history and drops everything that matters.
        store.setQueue(previous: nil, current: nil, next: [])

        #expect(store.queue.previousTracks.map(\.trackId) == ["played"])
        #expect(store.queue.currentTrack == nil)
        #expect(store.queue.nextTracks.isEmpty)
        // And the pointer is now unrepairable: the track is no longer in the list.
        #expect(!store.reconcileQueueCurrentTrack(with: "playing"))
    }
}
