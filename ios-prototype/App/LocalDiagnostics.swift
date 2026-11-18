import Foundation
import OSLog

/// Deliberately no free-form message, URL, request, cookie or user-metadata parameter.
enum DiagnosticCategory: String, CaseIterable {
    case playback, resolution, network, interruption, persistence, lifecycle
}

enum DiagnosticEvent: String, CaseIterable {
    case initializationFailed, resolutionFailed, catalogFailed, timedOut
    case interrupted, interruptionEnded, routeChanged, audioSessionFailed, playbackStalled
    case storageReadFailed, storageWriteFailed
    case backgrounded, foregrounded, memoryWarning, playerReleased
}

struct DiagnosticRecord: Equatable {
    let category: DiagnosticCategory
    let event: DiagnosticEvent
    let code: Int?

    /// Only fixed enum values and a bounded numeric status are ever emitted.
    var summary: String {
        let suffix = code.map { " code=\($0)" } ?? ""
        return "\(category.rawValue).\(event.rawValue)\(suffix)"
    }
}

/// Local-only bounded diagnostics. No files, upload endpoint, analytics or account identifiers.
/// The system Console receives the same safe categories retained by this in-memory ring.
final class LocalDiagnostics {
    static let shared = LocalDiagnostics()
    private let lock = NSLock()
    private let capacity: Int
    private var records: [DiagnosticRecord] = []
    private let logger = Logger(subsystem: "org.anilili.playbackpoc", category: "local-diagnostics")

    init(capacity: Int = 64) { self.capacity = min(256, max(1, capacity)) }

    func record(category: DiagnosticCategory, event: DiagnosticEvent, code: Int? = nil) {
        let safeCode = code.flatMap { (-99_999...99_999).contains($0) ? $0 : nil }
        let item = DiagnosticRecord(category: category, event: event, code: safeCode)
        lock.lock()
        // Repeated buffering/notification events must not flood the ring or Console.
        guard records.last != item else { lock.unlock(); return }
        records.append(item)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        lock.unlock()
        logger.info("\(item.summary, privacy: .public)")
    }

    func snapshot() -> [DiagnosticRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}
