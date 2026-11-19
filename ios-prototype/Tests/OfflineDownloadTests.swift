import AVFoundation
import Foundation
import SharedCore
import XCTest
@testable import PlaybackPOC

@MainActor
final class OfflineDownloadTests: XCTestCase {
    private func store() -> OfflineDownloadStore {
        OfflineDownloadStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func engine(_ store: OfflineDownloadStore, diskSpace: (() -> Int64)? = nil) -> OfflineDownloadEngine {
        OfflineDownloadEngine(store: store, allowLoopback: true,
            backgroundIdentifier: "org.anilili.offline.tests." + UUID().uuidString, diskSpace: diskSpace)
    }
    private func identity(_ episode: String = "offline-mp4") -> DownloadIdentity {
        DownloadIdentity(providerId: "demo-v1", animeId: "101", episodeId: episode)
    }
    private func source(_ path: String = "/progressive.mp4", format: PlaybackFormat = .mp4) -> PlaybackSource {
        PlaybackSource(episodeId: "offline-mp4", url: "http://127.0.0.1:8765" + path, format: format, headers: [:])
    }
    private func waitUntil(_ label: String, timeout: TimeInterval = 30, _ condition: @escaping () -> Bool) async throws {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Offline condition timed out: \(label)")
        throw NSError(domain: "OfflineDownloadTest", code: 1)
    }
    private func download(_ engine: OfflineDownloadEngine, source: PlaybackSource? = nil, id: DownloadIdentity? = nil) -> Bool {
        engine.download(identity: id ?? identity(), title: "Original offline fixture", episodeTitle: "Episode 1",
                        source: source ?? self.source(), episodeNumber: 1)
    }

    func testOwnedFileMoveAcceptsEquivalentDirectoryURLRepresentations() throws {
        for directoryHint in [false, true] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            let storage = OfflineDownloadStore(root: URL(fileURLWithPath: path, isDirectory: directoryHint))
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("original local test bytes".utf8).write(to: temporary)
            let key = UUID().uuidString + ".mp4"
            let destination = try storage.installProgressive(temporary: temporary, key: key)
            XCTAssertEqual(destination.deletingLastPathComponent().path, storage.root.path)
            XCTAssertEqual(try Data(contentsOf: destination), Data("original local test bytes".utf8))
            try storage.remove(key: key)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertThrowsError(try storage.installProgressive(temporary: temporary, key: "../other.mp4"))
        }
    }

    func testHLSReceiptsAcceptSystemSelectedSandboxDirectoriesAndRejectUnsafeLocations() throws {
        let storage = store()
        let files = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        for directory in ["Library", "Documents"] {
            let package = home.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(UUID().uuidString + ".movpkg", isDirectory: true)
            let key = UUID().uuidString + ".movpkg"
            // willDownloadTo can arrive before the package exists on disk.
            try storage.rememberHLS(location: package, key: key)
            XCTAssertNil(storage.hlsURL(key: key))
            try files.createDirectory(at: package, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: package) }
            XCTAssertEqual(storage.hlsURL(key: key)?.resolvingSymlinksInPath().path,
                           package.resolvingSymlinksInPath().path)
            let restored = OfflineDownloadStore(root: storage.root)
            XCTAssertEqual(restored.hlsURL(key: key)?.path, storage.hlsURL(key: key)?.path)
            let relative = URL(fileURLWithPath: directory + "/" + package.lastPathComponent,
                               isDirectory: true, relativeTo: home)
            try storage.rememberHLS(location: relative, key: key)
            XCTAssertEqual(storage.hlsURL(key: key)?.path, package.resolvingSymlinksInPath().path)
            try restored.remove(key: key)
            XCTAssertFalse(files.fileExists(atPath: package.path))
        }
        for invalid in [home, home.appendingPathComponent("Library"),
                        URL(fileURLWithPath: "/outside.movpkg"), URL(string: "https://example.invalid/media.movpkg")!] {
            XCTAssertThrowsError(try storage.rememberHLS(location: invalid, key: UUID().uuidString + ".movpkg"))
        }
        let target = home.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + ".movpkg", isDirectory: true)
        let link = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".movpkg")
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: target); try? files.removeItem(at: link) }
        try files.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try storage.rememberHLS(location: link, key: UUID().uuidString + ".movpkg"))
        XCTAssertThrowsError(try storage.rememberHLS(location: target, key: "../escape.movpkg"))
        XCTAssertTrue(files.fileExists(atPath: target.path))
    }

    func testMP4CompletesWithoutDuplicateAndSurvivesRepositoryRecreation() async throws {
        let storage = store()
        let first = engine(storage)
        defer { first.shutdown() }
        XCTAssertTrue(download(first))
        XCTAssertFalse(download(first))
        try await waitUntil("progressive completed") { first.records.first?.state == .completed || first.records.first?.state == .failed }
        XCTAssertEqual(first.records.first?.state, .completed, first.errorMessage ?? "Download did not complete")
        XCTAssertEqual(first.records.count, 1)
        let local = try XCTUnwrap(first.localURL(identity: identity()))
        XCTAssertTrue(local.isFileURL)
        XCTAssertGreaterThan(first.storageUsage, 0)
        let recreated = engine(storage)
        defer { recreated.shutdown() }
        XCTAssertEqual(recreated.localURL(identity: identity()), local)
        let player = PlaybackModel()
        defer { player.stop() }
        player.load(local); player.play()
        try await waitUntil("downloaded MP4 playback progressed") { player.seconds > 1 }
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.player.currentItem?.asset is AVURLAsset)
        XCTAssertEqual((player.player.currentItem?.asset as? AVURLAsset)?.url, local)
        print("Offline MP4 progressed=\(player.seconds), local=true, bytes=\(first.storageUsage)")
    }

    func testHLSNativePackagePlaysAfterItsOriginIsDisabled() async throws {
        let storage = store()
        let downloads = engine(storage)
        defer { downloads.shutdown() }
        let namespace = "/provider/offline/isolated/" + UUID().uuidString
        XCTAssertTrue(download(downloads, source: source(namespace + "/hls/master.m3u8", format: .hls)))
        try await waitUntil("native HLS package completed", timeout: 120) {
            downloads.records.first?.state == .completed || downloads.records.first?.state == .failed
        }
        XCTAssertEqual(downloads.records.first?.state, .completed, downloads.errorMessage ?? "HLS did not complete")
        let local = try XCTUnwrap(downloads.localURL(identity: identity()))
        let key = try XCTUnwrap(downloads.records.first?.localMediaKey)
        let reopened = OfflineDownloadStore(root: storage.root)
        let restored = try XCTUnwrap(reopened.hlsURL(key: key))
        XCTAssertEqual(restored.standardizedFileURL.path, local.standardizedFileURL.path)
        XCTAssertTrue(AVURLAsset(url: restored).assetCache?.isPlayableOffline == true)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765" + namespace + "/disable")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        let (_, disabled) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((disabled as? HTTPURLResponse)?.statusCode, 200)
        let (_, remote) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8765" + namespace + "/hls/master.m3u8")!)
        XCTAssertEqual((remote as? HTTPURLResponse)?.statusCode, 503)
        let player = PlaybackModel()
        defer { player.stop() }
        player.load(restored); player.play()
        try await waitUntil("HLS progressed with origin disabled") { player.seconds > 1 }
        XCTAssertNil(player.errorMessage)
        print("Offline native HLS progressed=\(player.seconds), playableOffline=true, originHTTP=503")
        player.stop()
        downloads.delete(record: try XCTUnwrap(downloads.records.first))
        XCTAssertNil(downloads.localURL(identity: identity()))
    }

    func testPauseResumeAndCancelDoNotReviveObsoleteTransfer() async throws {
        let downloads = engine(store())
        defer { downloads.shutdown() }
        XCTAssertTrue(download(downloads, source: source("/provider/offline/slow.mp4")))
        try await waitUntil("partial bytes") { (downloads.records.first?.bytesDownloaded ?? 0) > 0 }
        downloads.pause(record: try XCTUnwrap(downloads.records.first))
        XCTAssertEqual(downloads.records.first?.state, .paused)
        XCTAssertNil(downloads.localURL(identity: identity()))
        XCTAssertTrue(downloads.resume(record: try XCTUnwrap(downloads.records.first)))
        try await waitUntil("resumed completed") { downloads.records.first?.state == .completed || downloads.records.first?.state == .failed }
        XCTAssertEqual(downloads.records.first?.state, .completed, downloads.errorMessage ?? "Download did not complete")
        downloads.delete(record: try XCTUnwrap(downloads.records.first))
        XCTAssertTrue(download(downloads, source: source("/provider/offline/slow.mp4")))
        try await waitUntil("new partial bytes") { (downloads.records.first?.bytesDownloaded ?? 0) > 0 }
        downloads.cancel(record: try XCTUnwrap(downloads.records.first))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(downloads.records.first?.state, .cancelled)
        XCTAssertNil(downloads.localURL(identity: identity()))
        downloads.delete(record: try XCTUnwrap(downloads.records.first))
        XCTAssertTrue(download(downloads, source: source("/provider/offline/slow.mp4")))
        try await waitUntil("partial transfer before paused deletion") { (downloads.records.first?.bytesDownloaded ?? 0) > 0 }
        downloads.pause(record: try XCTUnwrap(downloads.records.first))
        downloads.delete(record: try XCTUnwrap(downloads.records.first))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(downloads.records.isEmpty, "Deleting paused media must also cancel its native task")
        XCTAssertEqual(downloads.storageUsage, 0)
    }

    func testPauseDuringProgressiveFinalizationRemovesStagedMedia() async throws {
        let storage = store()
        weak var active: OfflineDownloadEngine?
        var pausedKey: String?
        let downloads = OfflineDownloadEngine(store: storage, allowLoopback: true,
            backgroundIdentifier: "org.anilili.offline.tests." + UUID().uuidString,
            fingerprint: { store, key in
                guard let active, let record = active.records.first else { return nil }
                XCTAssertTrue(store.mediaExists(key: key))
                let checksum = try? store.calculatedFingerprint(key: key)
                active.pause(record: record)
                pausedKey = key
                return checksum
            })
        active = downloads
        defer { downloads.shutdown() }
        XCTAssertTrue(download(downloads))
        try await waitUntil("pause during MP4 verification") { pausedKey != nil || downloads.records.first?.state == .failed }
        let key = try XCTUnwrap(pausedKey, downloads.errorMessage ?? "MP4 verification did not begin")
        XCTAssertEqual(downloads.records.first?.state, .paused)
        XCTAssertFalse(storage.hasMediaOrReceipt(key: key))
        XCTAssertNil(downloads.localURL(identity: identity()))
    }

    func testStorageExhaustionAndHTTPFailureNeverCreateCompletedMedia() async throws {
        let full = engine(store(), diskSpace: { 0 })
        defer { full.shutdown() }
        XCTAssertTrue(download(full))
        try await waitUntil("no-space classification") { full.records.first?.state == .failed }
        XCTAssertEqual(full.records.first?.failure, .noSpace)
        XCTAssertNil(full.localURL(identity: identity()))
        let unavailable = engine(store())
        defer { unavailable.shutdown() }
        XCTAssertTrue(download(unavailable, source: source("/provider/status/403")))
        try await waitUntil("HTTP denied classification") { unavailable.records.first?.state == .failed }
        XCTAssertEqual(unavailable.records.first?.failure, .authentication)
        XCTAssertNil(unavailable.localURL(identity: identity()))
    }

    func testCorruptMediaAndTruncatedNetworkResponsesCannotComplete() async throws {
        for path in ["/provider/offline/invalid.mp4", "/provider/offline/truncated.mp4"] {
            let downloads = engine(store())
            defer { downloads.shutdown() }
            XCTAssertTrue(download(downloads, source: source(path)))
            try await waitUntil("invalid or interrupted media refused") { downloads.records.first?.state == .failed }
            XCTAssertNil(downloads.localURL(identity: identity()))
            XCTAssertEqual(downloads.storageUsage, 0)
        }
    }

    func testSameSizeCorruptionIsDetectedAndDeletePreservesUnrelatedFiles() async throws {
        let storage = store()
        let downloads = engine(storage)
        defer { downloads.shutdown() }
        XCTAssertTrue(download(downloads))
        try await waitUntil("complete before bit corruption") { downloads.records.first?.state == .completed || downloads.records.first?.state == .failed }
        XCTAssertEqual(downloads.records.first?.state, .completed, downloads.errorMessage ?? "Download did not complete")
        _ = try XCTUnwrap(downloads.records.first)
        let local = try XCTUnwrap(downloads.localURL(identity: identity()))
        let unrelated = storage.root.appendingPathComponent("user-owned.txt")
        try Data("preserve this file".utf8).write(to: unrelated)
        var media = try Data(contentsOf: local)
        media[media.count - 1] ^= 0x01
        try media.write(to: local, options: .atomic)
        XCTAssertNil(downloads.localURL(identity: identity()), "SHA-256 must detect same-size changed bytes")
        XCTAssertEqual(downloads.records.first?.state, .failed)
        XCTAssertEqual(downloads.records.first?.failure, .corrupt)
        downloads.delete(record: try XCTUnwrap(downloads.records.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertTrue(downloads.records.isEmpty)
        XCTAssertEqual(try String(contentsOf: unrelated), "preserve this file")
    }

    func testCorruptMetadataIsPreservedAndTraversalDeletionRefused() throws {
        let storage = store()
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        let metadata = storage.root.appendingPathComponent("downloads.json")
        try Data("{broken".utf8).write(to: metadata)
        let downloads = engine(storage)
        defer { downloads.shutdown() }
        XCTAssertNotNil(downloads.errorMessage)
        XCTAssertFalse(download(downloads))
        XCTAssertEqual(try String(contentsOf: metadata), "{broken")
        XCTAssertThrowsError(try storage.remove(key: "../unrelated.mp4"))
    }

    func testChangedCookiesRequireFreshRequestInsteadOfReusingOldResumeCredentials() async throws {
        let downloads = engine(store())
        defer { downloads.shutdown() }
        func gated(_ value: String) -> PlaybackSource {
            PlaybackSource(episodeId: "offline-mp4", url: "http://127.0.0.1:8765/provider/offline/gated.mp4",
                format: .mp4, headers: ["User-Agent": "AnililiFixture/1.0"],
                cookies: [PlaybackCookie(name: "fixture_session", value: value, domain: "127.0.0.1",
                    path: "/provider/offline", secure: false, expiresAtMs: nil)],
                redirectPolicy: .system, expiresAtMs: nil, audioTracks: [], subtitleTracks: [], requirements: [])
        }
        XCTAssertTrue(download(downloads, source: gated("authorized")))
        try await waitUntil("authorized gated download bytes") { (downloads.records.first?.bytesDownloaded ?? 0) > 0 }
        downloads.pause(record: try XCTUnwrap(downloads.records.first))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(download(downloads, source: gated("changed-cookie")))
        try await waitUntil("fresh changed credentials refused") { downloads.records.first?.state == .failed }
        XCTAssertEqual(downloads.records.first?.failure, .authentication)
        XCTAssertNil(downloads.localURL(identity: identity()))
    }

    func testExpiredSourceIsRejectedBeforeTransfer() {
        let downloads = engine(store())
        defer { downloads.shutdown() }
        let expired = PlaybackSource(episodeId: "offline-mp4", url: "https://example.invalid/private.mp4", format: .mp4,
            headers: [:], cookies: [], redirectPolicy: .system, expiresAtMs: KotlinLong(value: 1),
            audioTracks: [], subtitleTracks: [], requirements: [])
        XCTAssertFalse(download(downloads, source: expired))
        XCTAssertTrue(downloads.records.isEmpty)
        XCTAssertNotNil(downloads.errorMessage)
    }
}
