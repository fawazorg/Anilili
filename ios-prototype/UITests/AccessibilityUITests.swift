import XCTest

final class AccessibilityUITests: XCTestCase {
    func testDemoJourneyControlsRemainAccessibleAtLargestDynamicTypeInDarkMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--watch-history-ui-test", "--reset-watch-history-ui-test",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark"]
        app.launch()
        defer { app.terminate() }

        let search = app.textFields["journey.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        XCTAssertEqual(search.label, "Search original demo anime")
        assertTouchTarget(app.buttons["journey.search.submit"], in: app)
        let anime = app.buttons["journey.anime.101"]
        assertTouchTarget(anime, in: app)
        XCTAssertTrue(anime.label.contains("Anilili Demo Adventures"))
        anime.tap()

        let episode = app.buttons["journey.episode.demo-mp4"]
        assertTouchTarget(episode, in: app)
        episode.tap()
        let pause = app.buttons["player.pause"]
        assertTouchTarget(pause, in: app)
        XCTAssertEqual(pause.label, "Pause")
        pause.tap()
        let forward = app.buttons["player.seek-forward"]
        assertTouchTarget(forward, in: app)
        XCTAssertEqual(forward.label, "Seek forward ten seconds")
        let back = app.buttons["journey.playback.back"]
        assertTouchTarget(back, in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Largest Dynamic Type and Dark Mode controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        back.tap()
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        // This checks accessibility element labels and layout, not a running VoiceOver session.
    }

    private func assertTouchTarget(_ element: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), file: file, line: line)
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
    }
}
