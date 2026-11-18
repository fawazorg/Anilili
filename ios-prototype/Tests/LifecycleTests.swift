import AVFoundation
import UIKit
import SharedCore
import XCTest
@testable import PlaybackPOC

@MainActor
final class LifecycleTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "progressive", withExtension: "mp4", subdirectory: "Fixtures"))
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Lifecycle condition did not become true")
    }
    private func deliver(_ center: NotificationCenter, _ name: Notification.Name, info: [AnyHashable: Any]? = nil) async throws {
        center.post(name: name, object: nil, userInfo: info)
        // Notification handlers deliberately hop to the main actor.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testInterruptionFlushesAndRequiresExplicitPlay() async throws {
        let center = NotificationCenter()
        let model = PlaybackModel(notificationCenter: center, audioSession: LifecycleAudioSession())
        defer { model.stop() }
        var saved = 0.0
        model.onProgressSample = { position, _, immediate in if immediate { saved = position } }
        model.load(try fixture()); model.play()
        try await waitUntil { model.seconds > 0.5 }
        try await deliver(center, AVAudioSession.interruptionNotification, info: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertGreaterThan(saved, 0)
        model.play()
        XCTAssertEqual(model.player.rate, 0, "An active interruption must block explicit play")
        try await deliver(center, AVAudioSession.interruptionNotification, info: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue, AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertEqual(model.player.rate, 0)
        model.play()
        try await waitUntil { model.player.rate > 0 }
    }

    func testHeadphoneRemovalPausesAndFlushes() async throws {
        let center = NotificationCenter()
        let model = PlaybackModel(notificationCenter: center, audioSession: LifecycleAudioSession())
        defer { model.stop() }
        var immediateSamples = 0
        model.onProgressSample = { _, _, immediate in if immediate { immediateSamples += 1 } }
        model.load(try fixture()); model.play()
        try await waitUntil { model.seconds > 0.5 }
        let previous = immediateSamples
        try await deliver(center, AVAudioSession.routeChangeNotification, info: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertGreaterThan(immediateSamples, previous)
    }

    func testBackgroundDuringResumeCannotAutoplayAfterForeground() async throws {
        let center = NotificationCenter()
        let model = PlaybackModel(notificationCenter: center, audioSession: LifecycleAudioSession())
        defer { model.stop() }
        model.load(try fixture(), resumeSeconds: 3); model.play()
        try await deliver(center, UIApplication.didEnterBackgroundNotification)
        try await waitUntil { model.appliedResumeSeconds > 2.5 }
        model.play()
        XCTAssertEqual(model.player.rate, 0)
        try await deliver(center, UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(model.player.rate, 0)
        model.play()
        try await waitUntil { model.seconds > 3.5 }
    }

    func testMemoryWarningFlushesAndReleasesPlayer() async throws {
        let center = NotificationCenter()
        let model = PlaybackModel(notificationCenter: center, audioSession: LifecycleAudioSession())
        defer { model.stop() }
        var saved = 0.0
        model.onProgressSample = { position, _, immediate in if immediate { saved = position } }
        model.load(try fixture()); model.play()
        try await waitUntil { model.seconds > 0.5 }
        try await deliver(center, UIApplication.didReceiveMemoryWarningNotification)
        XCTAssertGreaterThan(saved, 0)
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.state, "Idle")
    }

    func testIdlePlayerCannotDeactivateActivePlayer() async throws {
        let audio = LifecycleAudioSession()
        let active = PlaybackModel(notificationCenter: NotificationCenter(), audioSession: audio)
        let idle = PlaybackModel(notificationCenter: NotificationCenter(), audioSession: audio)
        defer { active.stop(); idle.stop() }
        active.load(try fixture()); active.play()
        try await waitUntil { active.seconds > 0.5 }
        let count = audio.deactivations
        idle.stop()
        XCTAssertEqual(audio.deactivations, count)
        XCTAssertNotNil(audio.owner)
        active.pause()
        XCTAssertEqual(audio.deactivations, count + 1)
    }

    func testNewPlaybackSupersedesPreviousOwner() async throws {
        let audio = LifecycleAudioSession()
        let first = PlaybackModel(notificationCenter: NotificationCenter(), audioSession: audio)
        let second = PlaybackModel(notificationCenter: NotificationCenter(), audioSession: audio)
        defer { first.stop(); second.stop() }
        first.load(try fixture()); first.play()
        try await waitUntil { first.seconds > 0.5 }
        second.load(try fixture()); second.play()
        try await waitUntil { second.seconds > 0.5 }
        XCTAssertEqual(first.player.rate, 0)
        let count = audio.deactivations
        first.stop()
        XCTAssertEqual(audio.deactivations, count)
        XCTAssertGreaterThan(second.player.rate, 0)
    }

    func testBackgroundCancelsProviderResolutionAndRejectsLateResult() async throws {
        let center = NotificationCenter()
        let transport = LifecyclePendingTransport()
        let model = ProviderPlaybackModel(transport: transport, notificationCenter: center)
        defer { model.stop() }
        model.resolveAndPlay(endpoint: "https://example.invalid/known-server/iframe")
        try await waitUntil { transport.requestCount == 1 }
        try await deliver(center, UIApplication.didEnterBackgroundNotification)
        try await waitUntil { transport.cancelCount == 1 }
        transport.completeLate()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isResolving)
        XCTAssertNil(model.playback.player.currentItem)
    }

    func testDuplicateBackgroundEventsPreservePendingCatalogRetry() async throws {
        let center = NotificationCenter()
        let transport = LifecyclePendingTransport()
        let model = JourneyModel(transport: transport, notificationCenter: center)
        defer { model.leaveJourney() }
        model.loadCatalog()
        try await waitUntil { transport.requestCount == 1 }
        model.background() // SwiftUI scene callback and global notification may both arrive.
        try await deliver(center, UIApplication.didEnterBackgroundNotification)
        try await deliver(center, UIApplication.didBecomeActiveNotification)
        try await waitUntil { transport.requestCount == 2 }
        XCTAssertTrue(model.catalogModel.isLoading)
        XCTAssertNil(model.playback.player.currentItem)
    }

    func testRepeatedLoadsAndCleanupDoNotReviveObsoleteItem() async throws {
        let model = PlaybackModel(notificationCenter: NotificationCenter(), audioSession: LifecycleAudioSession())
        defer { model.stop() }
        model.load(try fixture(), resumeSeconds: 4); model.play()
        let obsolete = try XCTUnwrap(model.player.currentItem)
        model.stop()
        model.load(try fixture())
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: obsolete)
        try await waitUntil { model.player.currentItem?.status == .readyToPlay }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.player.rate, 0)
        model.stop()
        XCTAssertNil(model.player.currentItem)
    }
}

@MainActor
private final class LifecycleAudioSession: PlaybackAudioSession {
    private(set) var owner: UUID?
    private(set) var deactivations = 0
    private var supersede: (() -> Void)?
    func activate(owner: UUID, superseded: @escaping () -> Void) throws {
        guard self.owner != owner else { return }
        supersede?()
        self.owner = owner
        supersede = superseded
    }
    func deactivate(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        supersede = nil
        deactivations += 1
    }
}

private final class LifecyclePendingTransport: NSObject, CatalogCallbackTransport {
    private let lock = NSLock()
    private var requests = 0
    private var cancellations = 0
    private var completion: CatalogHttpCompletion?
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        lock.lock(); requests += 1; self.completion = completion; lock.unlock()
        return LifecycleCancellation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.cancellations += 1; self.lock.unlock()
        }
    }
    func completeLate() {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?.complete(response: CatalogHttpResponse(status: 200, body: "{\"link\":\"https://example.invalid/video.mp4\",\"format\":\"MP4\"}"), error: nil)
    }
}
private final class LifecycleCancellation: NSObject, CatalogCancellation {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init() }
    func cancel() { action() }
}
