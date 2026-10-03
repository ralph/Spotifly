//
//  StoppedReportTests.swift
//  SpotiflyTests
//
//  What this Mac tells the cluster when playback stops here: at a disconnect, and when it lets
//  go over an error.
//

@testable import Spotifly
import Testing

struct StoppedReportTests {
    /// The moment of the last report.
    private static let reportedAt: UInt64 = 1_790_000_000_000

    private func state(playing: Bool, positionMs: UInt64 = 2837, durationMs: UInt64 = 215_205) -> SpircController.SpircPlayerState {
        SpircController.SpircPlayerState(
            isPlaying: playing,
            isPaused: !playing,
            trackUri: "spotify:track:t1",
            positionMs: positionMs,
            durationMs: durationMs,
            shuffle: true,
            repeatMode: .off,
            timestamp: Self.reportedAt,
            contextUri: "spotify:album:a",
            trackProvider: "context",
            trackUid: nil,
            nextTracks: [],
            previousTracks: [],
        )
    }

    /// As measured on 2026-10-03: the last report at 2837 ms, the failure 7.2 s later.
    @Test func `a playing track stops where it had got to, paused`() {
        let stopped = SpircController.stopped(state(playing: true), atMs: Self.reportedAt + 7242)

        #expect(stopped.positionMs == 10079)
        #expect(!stopped.isPlaying)
        #expect(stopped.isPaused)
        #expect(stopped.timestamp == Self.reportedAt + 7242)
        #expect(stopped.trackUri == "spotify:track:t1")
        #expect(stopped.shuffle)
    }

    /// A release is paused when playback stops and sent later; sending it moves nothing.
    @Test func `a state already stopped stays where it stopped`() {
        let stopped = SpircController.stopped(state(playing: true), atMs: Self.reportedAt + 7242)
        let sent = SpircController.stopped(stopped, atMs: Self.reportedAt + 22242)

        #expect(sent.positionMs == 10079)
        #expect(sent.timestamp == Self.reportedAt + 22242)
    }

    @Test func `a paused track stops where it was`() {
        let stopped = SpircController.stopped(state(playing: false), atMs: Self.reportedAt + 60000)

        #expect(stopped.positionMs == 2837)
        #expect(stopped.isPaused)
    }

    @Test func `a track that would have ended stops at its end`() {
        let stopped = SpircController.stopped(state(playing: true, positionMs: 214_000), atMs: Self.reportedAt + 5000)

        #expect(stopped.positionMs == 215_205)
    }

    /// No length to stop at: the time played is all there is.
    @Test func `a track of unknown length runs on by the time played`() {
        let stopped = SpircController.stopped(state(playing: true, durationMs: 0), atMs: Self.reportedAt + 5000)

        #expect(stopped.positionMs == 7837)
    }
}
