import Foundation
import XCTest
@testable import PlaybackPOC

final class DiagnosticsTests: XCTestCase {
    func testDiagnosticsContainOnlyAllowlistedCategoriesAndBoundedCodes() {
        let log = LocalDiagnostics(capacity: 8)
        log.record(category: .network, event: .timedOut, code: -1001)
        log.record(category: .resolution, event: .resolutionFailed, code: 403)
        log.record(category: .playback, event: .initializationFailed, code: -11800)
        log.record(category: .playback, event: .initializationFailed, code: Int.max)
        XCTAssertEqual(log.snapshot().map(\.summary), [
            "network.timedOut code=-1001", "resolution.resolutionFailed code=403",
            "playback.initializationFailed code=-11800", "playback.initializationFailed"
        ])
        let output = log.snapshot().map(\.summary).joined(separator: "\n")
        // There is no String/context argument through which these values can enter a record.
        for sensitive in ["https://fixture.invalid/private?token=secret", "Cookie", "Bearer", "secret", String(Int.max)] {
            XCTAssertFalse(output.contains(sensitive))
        }
    }

    func testDiagnosticsDeduplicateRepeatedEventsAndBoundRetention() {
        let log = LocalDiagnostics(capacity: 3)
        log.record(category: .playback, event: .playbackStalled)
        log.record(category: .playback, event: .playbackStalled)
        XCTAssertEqual(log.snapshot().count, 1)
        for code in 1...4 { log.record(category: .resolution, event: .resolutionFailed, code: code) }
        XCTAssertEqual(log.snapshot().map(\.code), [2, 3, 4])
    }

    func testConcurrentDiagnosticsRemainWithinCapacityAndWellFormed() {
        let log = LocalDiagnostics(capacity: 16)
        DispatchQueue.concurrentPerform(iterations: 64) { code in
            log.record(category: .network, event: .timedOut, code: code)
        }
        let records = log.snapshot()
        XCTAssertEqual(records.count, 16)
        XCTAssertTrue(records.allSatisfy { $0.category == .network && $0.event == .timedOut })
        XCTAssertTrue(records.allSatisfy { (0..<64).contains($0.code ?? -1) })
    }
}
