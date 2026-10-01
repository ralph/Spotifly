//
//  NetworkMonitorTests.swift
//  SpotiflyTests
//
//  When the network counts as back, for artwork that asks again.
//

@testable import Spotifly
import Testing

@MainActor
struct NetworkMonitorTests {
    @Test func `a return is counted only after the network was away`() {
        let monitor = NetworkMonitor(satisfied: true)

        monitor.update(satisfied: true)
        #expect(monitor.returns == 0)

        monitor.update(satisfied: false)
        monitor.update(satisfied: false)
        #expect(monitor.returns == 0)

        monitor.update(satisfied: true)
        #expect(monitor.returns == 1)

        monitor.update(satisfied: true)
        #expect(monitor.returns == 1)
    }

    /// What artwork reads to show its placeholder rather than a spinner.
    @Test func `it says whether the network is there`() {
        let monitor = NetworkMonitor(satisfied: true)
        #expect(monitor.isOnline)

        monitor.update(satisfied: false)
        #expect(!monitor.isOnline)

        monitor.update(satisfied: true)
        #expect(monitor.isOnline)
    }

    /// Launched offline, the first report is a return as soon as the network is there.
    @Test func `launched offline, coming online is a return`() {
        let monitor = NetworkMonitor(satisfied: false)

        monitor.update(satisfied: true)

        #expect(monitor.returns == 1)
    }
}
