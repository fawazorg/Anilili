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
        assertTouchTarget(episode, in: app)
        // This checks accessibility element labels and layout, not a running VoiceOver session.
    }

    private func assertTouchTarget(_ element: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        // SwiftUI List creates offscreen rows lazily, especially at accessibility sizes.
        // Scroll even when the element does not exist yet; waiting alone cannot reveal it.
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<12 {
            if element.exists && element.isHittable { break }
            let playback = app.scrollViews["journey.playback"]
            let container = playback.exists ? playback : (app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app)
            // Large swipes can jump from below the tab bar to above the navigation bar.
            // Follow the target's current position and use a short drag at the content edge,
            // outside AVPlayer's own gesture surface.
            let moveDown = element.exists && element.frame.midY < container.frame.midY
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: moveDown ? 0.35 : 0.65))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: moveDown ? 0.65 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
    }
}
