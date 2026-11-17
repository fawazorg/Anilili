import Foundation
import SharedCore

/// One lock per canonical path protects compare-and-swap across repository instances in this process.
/// Atomic replacement leaves either the old complete snapshot or the new complete snapshot on disk.
final class HistoryFileStorage: NSObject {
    private static let registryLock = NSLock()
    private static var locks: [String: NSLock] = [:]
    let fileURL: URL
    private let lock: NSLock

    init(fileURL: URL) {
        let normalized = fileURL.standardizedFileURL
        self.fileURL = normalized
        Self.registryLock.lock()
        if let existing = Self.locks[normalized.path] { lock = existing }
        else { let created = NSLock(); Self.locks[normalized.path] = created; lock = created }
        Self.registryLock.unlock()
        super.init()
    }

    func readSnapshot() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try readUnlocked()
    }

    func replaceSnapshot(expected: String?, updated: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard try readUnlocked() == expected else { return false }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: fileURL, options: .atomic)
        return true
    }

    private func readUnlocked() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AnililiHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Watch history is not valid UTF-8."])
        }
        return value
    }

    static func applicationURL() -> URL {
        // UI tests opt into an isolated file; ordinary launches never reset user history.
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let arguments = ProcessInfo.processInfo.arguments
        let name = arguments.contains("--watch-history-ui-test") ? "watch-history-ui-test.json" : "watch-history.json"
        let url = directory.appendingPathComponent("Anilili", isDirectory: true).appendingPathComponent(name)
        if arguments.contains("--watch-history-ui-test") && arguments.contains("--reset-watch-history-ui-test") {
            // Remove only this explicitly selected test file, never production history.
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

extension HistoryFileStorage: WatchHistoryStorage {
    func read() -> HistoryStorageRead {
        do { return HistoryStorageRead(content: try readSnapshot(), error: nil) }
        catch { return HistoryStorageRead(content: nil, error: "Watch history could not be read. Existing data was preserved.") }
    }

    func compareAndSet(expected: String?, updated: String) -> HistoryStorageWrite {
        do { return HistoryStorageWrite(written: try replaceSnapshot(expected: expected, updated: updated), error: nil) }
        catch { return HistoryStorageWrite(written: false, error: "Watch history could not be saved. Please try again.") }
    }
}

/// Used only for explicitly injected ephemeral journeys and deterministic tests.
final class MemoryHistoryStorage: NSObject, WatchHistoryStorage {
    private let lock = NSLock()
    private var content: String?
    func read() -> HistoryStorageRead {
        lock.lock(); defer { lock.unlock() }
        return HistoryStorageRead(content: content, error: nil)
    }
    func compareAndSet(expected: String?, updated: String) -> HistoryStorageWrite {
        lock.lock(); defer { lock.unlock() }
        guard content == expected else { return HistoryStorageWrite(written: false, error: nil) }
        content = updated
        return HistoryStorageWrite(written: true, error: nil)
    }
}
