//
//  PlaybackViewModelTests.swift
//  SpotiflyTests
//
//  Validation of the playback measurements that arrive in Connect snapshots.
//

@testable import Spotifly
import Testing

struct PlaybackMillisecondsTests {
    @Test func `ordinary playback measurements are accepted`() {
        #expect(PlaybackViewModel.playbackMilliseconds(123_456) == 123_456)
        #expect(PlaybackViewModel.playbackMilliseconds(Int64(UInt32.max)) == UInt32.max)
    }

    @Test func `negative playback measurements are ignored`() {
        #expect(PlaybackViewModel.playbackMilliseconds(-1) == nil)
    }

    /// A captured Connect snapshot supplied the crash time in Unix milliseconds as the
    /// position. Converting it directly to `UInt32` raised `EXC_BREAKPOINT` on the main
    /// thread rather than merely producing an unusable progress value.
    @Test func `a timestamp-shaped playback position is ignored rather than trapping`() {
        #expect(PlaybackViewModel.playbackMilliseconds(1_787_161_786_267) == nil)
        #expect(PlaybackViewModel.playbackMilliseconds(Int64(UInt32.max) + 1) == nil)
    }
}
