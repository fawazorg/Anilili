import AVFoundation
import XCTest
@testable import PlaybackPOC

@MainActor
final class PlaybackTests: XCTestCase {
    private var model: PlaybackModel!
    override func setUp() async throws { model = PlaybackModel() }
    override func tearDown() async throws { model.stop(); model = nil }

    private func waitUntil(_ description: String, timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            if let error = model.errorMessage { XCTFail("\(description): \(error)"); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out: \(description); state=\(model.state), seconds=\(model.seconds)")
    }
    private func verifyPlayback(_ path: String) async throws {
        model.load(URL(string: "http://127.0.0.1:8765/\(path)")!)
        model.play()
        try await waitUntil("playback progressed") { self.model.seconds > 1 && self.model.player.timeControlStatus == .playing }
        print("Observed \(path): state=\(model.state), time=\(model.seconds)")
        model.pause()
        let pausedAt = model.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.player.currentTime().seconds, pausedAt, accuracy: 0.25)
        model.seek(by: 3)
        try await waitUntil("seek forward") { self.model.player.currentTime().seconds >= pausedAt + 2.5 }
        model.seek(by: -2)
        try await waitUntil("seek backward") { self.model.player.currentTime().seconds < pausedAt + 2 }
        model.stop()
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.state, "Idle")
        XCTAssertEqual(model.seconds, 0)
        XCTAssertTrue(model.audioOptions.isEmpty)
        XCTAssertTrue(model.subtitleOptions.isEmpty)
    }
    func testProgressivePlaybackPauseSeekCleanup() async throws { try await verifyPlayback("progressive.mp4") }
    func testHLSPlaybackPauseSeekCleanup() async throws { try await verifyPlayback("hls/index.m3u8") }
    func testUserAgentPlayback() async throws {
        model.load(URL(string: "http://127.0.0.1:8765/progressive.mp4")!, headers: ["User-Agent": "AnililiPlaybackPOC/1.0"])
        model.play()
        try await waitUntil("User-Agent playback progressed") { self.model.seconds > 1 }
    }
    func testHLSAudioAndSubtitleSelection() async throws {
        model.load(URL(string: "http://127.0.0.1:8765/hls/master.m3u8")!)
        model.play()
        try await waitUntil("master playback and track discovery") {
            self.model.seconds > 1 && self.model.audioOptions.count >= 2 && !self.model.subtitleOptions.isEmpty
        }
        guard let item = model.player.currentItem,
              let audio = try await item.asset.loadMediaSelectionGroup(for: .audible),
              let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible),
              let chosenAudio = model.audioOptions.last,
              let chosenSubtitle = model.subtitleOptions.first else {
            XCTFail("Missing required fixture tracks"); return
        }
        model.selectAudio(chosenAudio)
        model.selectSubtitle(chosenSubtitle)
        try await waitUntil("track selection applied") {
            item.currentMediaSelection.selectedMediaOption(in: audio) == chosenAudio &&
            item.currentMediaSelection.selectedMediaOption(in: subtitles) == chosenSubtitle
        }
        let selectedAt = model.seconds
        try await waitUntil("playback progressed after track selection") { self.model.seconds > selectedAt + 0.5 }
        model.selectSubtitle(nil)
        try await waitUntil("subtitle off") { item.currentMediaSelection.selectedMediaOption(in: subtitles) == nil }
        print("Selected audio=\(chosenAudio.displayName), subtitles=\(chosenSubtitle.displayName), playback=\(model.seconds)")
    }
    func testUnsupportedHeadersFailExplicitly() {
        model.load(URL(string: "https://example.invalid/media.m3u8")!, headers: ["Referer": "https://example.invalid"])
        XCTAssertEqual(model.state, "Error")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.player.currentItem)
    }
    func testInvalidSchemeFailsExplicitly() {
        model.load(URL(string: "ftp://example.invalid/media.mp4")!)
        XCTAssertEqual(model.state, "Error")
        XCTAssertNil(model.player.currentItem)
    }
    func testMissingMediaReportsError() async throws {
        model.load(URL(string: "http://127.0.0.1:8765/missing.mp4")!)
        model.play()
        let end = Date().addingTimeInterval(20)
        while Date() < end && model.errorMessage == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.state, "Error")
    }
    func testCancelWhileLoadingDoesNotReviveItem() async throws {
        model.load(URL(string: "http://127.0.0.1:8765/hls/index.m3u8")!)
        model.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.state, "Idle")
        XCTAssertTrue(model.audioOptions.isEmpty)
    }
}
