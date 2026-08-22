//
//  QueueReconciliationTests.swift
//  SpotiflyTests
//
//  Queue pointer reconciliation contracts.
//

@testable import Spotifly
import Testing

@MainActor
struct QueueReconciliationTests {
    private func entry(_ id: String) -> QueueEntry {
        QueueEntry(trackId: id, provider: .context)
    }

    private func queue(ids: [String], currentIndex: Int) -> Queue {
        Queue(
            previousTracks: ids[..<currentIndex].map(entry),
            currentTrack: entry(ids[currentIndex]),
            nextTracks: ids[(currentIndex + 1)...].map(entry),
        )
    }

    @Test func `an already correct split is unchanged`() {
        let original = queue(ids: ["one", "two", "three"], currentIndex: 1)

        #expect(original.reconciled(currentTrackId: "two") == original)
    }

    @Test func `a split one track behind moves forward`() {
        let result = queue(ids: ["one", "two", "three"], currentIndex: 0)
            .reconciled(currentTrackId: "two")

        #expect(result.previousTracks.map(\.trackId) == ["one"])
        #expect(result.currentTrack?.trackId == "two")
        #expect(result.nextTracks.map(\.trackId) == ["three"])
    }

    @Test func `a split eleven tracks behind moves forward eleven tracks`() {
        let ids = (1 ... 18).map { "track-\($0)" }
        let result = queue(ids: ids, currentIndex: 0)
            .reconciled(currentTrackId: "track-12")

        #expect(result.previousTracks.map(\.trackId) == Array(ids.prefix(11)))
        #expect(result.currentTrack?.trackId == "track-12")
        #expect(result.nextTracks.map(\.trackId) == Array(ids.suffix(6)))
    }

    @Test func `a split ahead of playback moves backward`() {
        let result = queue(ids: ["one", "two", "three", "four", "five"], currentIndex: 4)
            .reconciled(currentTrackId: "two")

        #expect(result.previousTracks.map(\.trackId) == ["one"])
        #expect(result.currentTrack?.trackId == "two")
        #expect(result.nextTracks.map(\.trackId) == ["three", "four", "five"])
    }

    @Test func `an absent playing track leaves the queue unchanged`() {
        let original = queue(ids: ["one", "two", "three"], currentIndex: 1)

        #expect(original.reconciled(currentTrackId: "absent") == original)
    }

    @Test func `a duplicate nearer behind the split is selected`() {
        let original = queue(
            ids: ["one", "two", "duplicate", "three", "reported", "four", "five", "duplicate"],
            currentIndex: 4,
        )
        let result = original.reconciled(currentTrackId: "duplicate")

        #expect(result.currentTrack?.trackId == "duplicate")
        #expect(result.previousTracks.map(\.trackId) == ["one", "two"])
    }

    @Test func `a duplicate nearer ahead of the split is selected`() {
        let original = queue(
            ids: ["duplicate", "one", "two", "reported", "duplicate", "three", "four"],
            currentIndex: 3,
        )
        let result = original.reconciled(currentTrackId: "duplicate")

        #expect(result.currentTrack?.trackId == "duplicate")
        #expect(result.previousTracks.map(\.trackId) == ["duplicate", "one", "two", "reported"])
    }

    @Test func `the last entry can become current`() {
        let result = queue(ids: ["one", "two", "three"], currentIndex: 0)
            .reconciled(currentTrackId: "three")

        #expect(result.previousTracks.map(\.trackId) == ["one", "two"])
        #expect(result.currentTrack?.trackId == "three")
        #expect(result.nextTracks.isEmpty)
    }

    @Test func `reconciling twice is idempotent`() {
        let first = queue(ids: ["one", "two", "three"], currentIndex: 0)
            .reconciled(currentTrackId: "three")
        let second = first.reconciled(currentTrackId: "three")

        #expect(second == first)
    }
}
