import XCTest

final class WatchHistoryUITests: XCTestCase {
    private func seconds(_ element: XCUIElement) -> Double {
        guard let text = element.label.components(separatedBy: "·").last else { return -1 }
        return Double(text.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)) ?? -1
    }

    func testPersistedContinueWatchingResumesAfterApplicationRestart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The isolated history-test launch uses a 120-second original fixture, leaving time
        // for accessibility snapshots after resume; progression assertions remain mandatory.
        app.launchArguments = ["--watch-history-ui-test", "--reset-watch-history-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let anime = app.buttons["journey.anime.101"]
        XCTAssertTrue(anime.waitForExistence(timeout: 30))
        anime.tap()
        let episode = app.buttons["journey.episode.demo-mp4"]
        XCTAssertTrue(episode.waitForExistence(timeout: 20))
        episode.tap()
        let progress = app.staticTexts["player.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        expectation(for: NSPredicate { _, _ in self.seconds(progress) > 5 }, evaluatedWith: progress)
        waitForExpectations(timeout: 30)
        let pause = app.buttons["player.pause"]
        for _ in 0..<4 where !pause.isHittable { app.swipeUp() }
        pause.tap()
        // Explicit pause flushes the clock before process termination; no ten-second wait is needed.
        app.terminate()
        app.launchArguments = ["--watch-history-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let continuing = app.buttons["history.continue.demo-mp4"]
        XCTAssertTrue(continuing.waitForExistence(timeout: 30), "Continue Watching must survive application restart")
        continuing.tap()
        let resumed = app.staticTexts["history.resume"]
        XCTAssertTrue(resumed.waitForExistence(timeout: 20), "The shared repository must provide a nonzero saved resume position")
        let resumedProgress = app.staticTexts["player.progress"]
        XCTAssertTrue(resumedProgress.waitForExistence(timeout: 20))
        expectation(for: NSPredicate { _, _ in self.seconds(resumedProgress) > 2 }, evaluatedWith: resumedProgress)
        waitForExpectations(timeout: 20)
        let observed = seconds(resumedProgress)
        expectation(for: NSPredicate { _, _ in
            resumedProgress.label.contains("Playing") && self.seconds(resumedProgress) > observed + 0.3
        }, evaluatedWith: resumedProgress)
        waitForExpectations(timeout: 15)
        print("Restarted persisted Continue Watching: \(resumed.label); actual player=\(resumedProgress.label)")
    }
}
