//
//  SpotiflyUITests.swift
//  SpotiflyUITests
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import XCTest

final class SpotiflyUITests: XCTestCase {
    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
