//
//  IOSTemplateAppUITests.swift
//  IOSTemplateAppUITests
//
//  Created by 村石 拓海 on 2024/05/12.
//

import XCTest

final class IOSTemplateAppUITests: XCTestCase {
    override func setUpWithError() throws {
        // UI テストでは失敗した時点で即座に止める
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsContentView() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Hello, world!"].waitForExistence(timeout: 5))
    }
}
