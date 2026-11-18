import CryptoKit
import Foundation
import SharedCore

/// App-owned progressive files and metadata. HLS packages stay where AVFoundation puts them.
final class OfflineDownloadStore: NSObject, DownloadStorage {
    let root: URL
    private let metadata: HistoryFileStorage
    private let files = FileManager.default

    init(root: URL = OfflineDownloadStore.applicationRoot()) {
        self.root = URL(fileURLWithPath: root.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
        metadata = HistoryFileStorage(fileURL: self.root.appendingPathComponent("downloads.json"))
        super.init()
    }

    static func applicationRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnililiOffline", isDirectory: true)
    }
    func read() -> DownloadStorageRead {
        do { return DownloadStorageRead(content: try metadata.readSnapshot(), error: nil) }
        catch { return DownloadStorageRead(content: nil, error: "Download metadata could not be read. Existing data was preserved.") }
    }
    func compareAndSet(expected: String?, updated: String) -> DownloadStorageWrite {
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            var directory = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            return DownloadStorageWrite(written: try metadata.replaceSnapshot(expected: expected, updated: updated), error: nil)
        }
        catch { return DownloadStorageWrite(written: false, error: "Download metadata could not be saved.") }
    }
    private func owned(_ key: String) throws -> URL {
        guard key.range(of: "^[0-9A-Fa-f-]{36}\\.(mp4|movpkg)$", options: .regularExpression) != nil,
              UUID(uuidString: String(key.prefix(36))) != nil else { throw Failure.invalidPath }
        let value = root.appendingPathComponent(key).standardizedFileURL
        guard value.deletingLastPathComponent().path == root.path,
              value.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path else { throw Failure.invalidPath }
        return value
    }
    func installProgressive(temporary: URL, key: String) throws -> URL {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = try owned(key)
        guard !files.fileExists(atPath: destination.path) else { throw Failure.invalidPath }
        try files.moveItem(at: temporary, to: destination)
        return destination
    }
    func availableBytes() -> Int64 {
        let ancestor = files.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        return (try? ancestor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }
    func size(_ url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let list = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in list {
            guard child.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().path + "/"),
                  let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
    func calculatedFingerprint(key: String) throws -> String { try hash(owned(key)) }
    func writeFingerprint(key: String, fingerprint: String) throws {
        let url = try owned(key)
        try Data(fingerprint.utf8).write(to: url.appendingPathExtension("integrity"), options: .atomic)
    }
    private func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func progressiveURL(key: String, expectedBytes: Int64, checkFingerprint: Bool = true) -> URL? {
        guard key.hasSuffix(".mp4"), let url = try? owned(key), size(url) == expectedBytes, expectedBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32), data.count >= 12,
              data.subdata(in: 4..<8) == Data("ftyp".utf8) else { return nil }
        if checkFingerprint {
            guard let stored = try? String(contentsOf: url.appendingPathExtension("integrity"), encoding: .utf8),
                  let current = try? hash(url), stored == current else { return nil }
        }
        return url
    }
    private struct PackageReceipt: Codable { let relative: String; let digest: String }
    private func binding(_ key: String, _ relative: String) -> String {
        SHA256.hash(data: Data((key + "\0" + relative).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func pointer(_ key: String) throws -> URL { try owned(key).appendingPathExtension("location") }
    enum HLSLocationFailure: String, Error {
        case notFileURL, outsideSandbox, unexpectedPackageType, symbolicLink
    }
    private func validatedSystemPackage(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw HLSLocationFailure.notFileURL }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        let resolved = url.absoluteURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(home.path + "/") else { throw HLSLocationFailure.outsideSandbox }
        guard resolved.pathExtension == "movpkg" else { throw HLSLocationFailure.unexpectedPackageType }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw HLSLocationFailure.symbolicLink
        }
        return resolved
    }
    private func safeSystemPackage(_ url: URL) -> Bool { (try? validatedSystemPackage(url)) != nil }
    func rememberHLS(location: URL, key: String) throws {
        guard key.hasSuffix(".movpkg") else { throw Failure.invalidPath }
        let package = try validatedSystemPackage(location)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().path + "/"
        let canonical = package.path
        guard canonical.hasPrefix(home) else { throw Failure.invalidPath }
        let relative = String(canonical.dropFirst(home.count))
        let receipt = PackageReceipt(relative: relative, digest: binding(key, relative))
        try JSONEncoder().encode(receipt).write(to: pointer(key), options: .atomic)
    }
    func hlsURL(key: String) -> URL? {
        guard key.hasSuffix(".movpkg"), let file = try? pointer(key),
              let data = try? Data(contentsOf: file), let receipt = try? JSONDecoder().decode(PackageReceipt.self, from: data),
              receipt.digest == binding(key, receipt.relative),
              !receipt.relative.hasPrefix("/"), !receipt.relative.split(separator: "/").contains("..") else { return nil }
        let value = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(receipt.relative)
        return safeSystemPackage(value) && files.fileExists(atPath: value.path) ? value : nil
    }
    func mediaExists(key: String) -> Bool {
        if key.hasSuffix(".movpkg") { return hlsURL(key: key) != nil }
        guard let url = try? owned(key) else { return false }
        return files.fileExists(atPath: url.path)
    }
    func hasMediaOrReceipt(key: String) -> Bool {
        guard let url = try? (key.hasSuffix(".movpkg") ? pointer(key) : owned(key)) else { return false }
        return files.fileExists(atPath: url.path)
    }
    func remove(key: String) throws {
        if key.hasSuffix(".movpkg") {
            // Only a previously registered local package can be deleted; never scan the sandbox.
            if let package = hlsURL(key: key) { try files.removeItem(at: package) }
            let receipt = try pointer(key)
            if files.fileExists(atPath: receipt.path) { try files.removeItem(at: receipt) }
        } else {
            let file = try owned(key)
            if files.fileExists(atPath: file.path) { try files.removeItem(at: file) }
            let receipt = file.appendingPathExtension("integrity")
            if files.fileExists(atPath: receipt.path) { try files.removeItem(at: receipt) }
        }
    }
    enum Failure: Error { case invalidPath }
}
