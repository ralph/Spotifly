//
//  PlaybackViewModelTests.swift
//  SpotiflyTests
//
//  Validation of the playback measurements that arrive in Connect snapshots.
//

import Foundation
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

/// The clock the displayed position runs on.
struct PositionClockTests {
    /// Seen on 2026-10-02: a phone played, the Mac slept for about 45 s, and the bar came back
    /// behind the phone by that long. Its clock, `CACurrentMediaTime`, stops in sleep, while a
    /// report's age is wall-clock time. The position clock has to have run with the wall clock
    /// since boot, asleep or not. A clock that stops in sleep is behind it by every second this
    /// Mac has slept since boot; on one that has not slept, this cannot tell the two apart.
    @Test func `the position clock is the wall clock since boot and so counts sleep`() throws {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        try #require(sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0)
        let boot = Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000
        let wallSinceBoot = Date().timeIntervalSince1970 - boot

        // A second is far more than the readings take apart, and far less than a sleep.
        #expect(abs(PlaybackViewModel.positionClockNow() - wallSinceBoot) < 1)
    }
}
