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
    /// A clock that stops in sleep is behind the wall clock by every second this Mac has slept
    /// since boot; on a Mac that has not slept, this cannot tell the two apart.
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

/// The pause macOS sends the now-playing app as the Mac goes to sleep. Seen on 2026-10-02: it
/// was sent on to a playing phone, which stopped each time the Mac slept.
struct SleepPauseTests {
    private let willSleepAt = Date(timeIntervalSince1970: 1_000_000)

    @Test func `a pause as the Mac goes to sleep is dropped while another device plays`() {
        #expect(PlaybackViewModel.isSleepPause(
            willSleepAt: willSleepAt,
            now: willSleepAt.addingTimeInterval(0.5),
            isActiveDevice: false,
        ))
    }

    @Test func `this Mac's own playback still pauses for the sleep`() {
        #expect(!PlaybackViewModel.isSleepPause(
            willSleepAt: willSleepAt,
            now: willSleepAt.addingTimeInterval(0.5),
            isActiveDevice: true,
        ))
    }

    /// A sleep that never came, and so never woke, must not silence the pause key for good.
    @Test func `a pause long after a sleep that never came goes through`() {
        #expect(!PlaybackViewModel.isSleepPause(
            willSleepAt: willSleepAt,
            now: willSleepAt.addingTimeInterval(60),
            isActiveDevice: false,
        ))
        #expect(!PlaybackViewModel.isSleepPause(willSleepAt: nil, now: willSleepAt, isActiveDevice: false))
    }
}
