import XCTest

final class JourneyUITests: XCTestCase {
    func testPrimaryTabsExposeDownloadsAndManualPlaybackSettings() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        let tabs = app.tabBars
        XCTAssertTrue(tabs.buttons["Browse"].exists)
        XCTAssertTrue(tabs.buttons["Search"].exists)

        tabs.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))

        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings.manualPlayback"].tap()
        XCTAssertTrue(app.textFields["playback.address"].waitForExistence(timeout: 5))

        tabs.buttons["Browse"].tap()
        XCTAssertTrue(app.textFields["journey.search"].waitForExistence(timeout: 5))
        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.textFields["playback.address"].waitForExistence(timeout: 5),
                      "Settings should preserve its navigation destination across tab changes")
    }

    func testDemoCatalogToEpisodePlaybackAndBack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let anime = app.buttons["journey.anime.101"]
        XCTAssertTrue(anime.waitForExistence(timeout: 30), "Shared demo catalog must load on launch")
        anime.tap()
        let episode = app.buttons["journey.episode.demo-mp4"]
        XCTAssertTrue(episode.waitForExistence(timeout: 20), "Shared provider episode list must be displayed")
        for _ in 0..<4 where !episode.isHittable { app.swipeUp() }
        episode.tap()
        let progress = app.staticTexts["player.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 20), "Episode resolution must open the player")
        let progressed = NSPredicate { _, _ in
            let pieces = progress.label.components(separatedBy: "·")
            guard let last = pieces.last,
                  let seconds = Double(last.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)) else { return false }
            return seconds > 1
        }
        expectation(for: progressed, evaluatedWith: progress)
        waitForExpectations(timeout: 30)
        print("UI journey actual playback: \(progress.label)")
        let back = app.buttons["journey.playback.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        for _ in 0..<4 where !back.isHittable { app.swipeUp() }
        back.tap()
        XCTAssertTrue(episode.waitForExistence(timeout: 10), "Back must restore the episode list")
        XCTAssertFalse(progress.exists, "Player view must leave the navigation stack")
    }
}
