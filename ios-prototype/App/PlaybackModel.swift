import AVFoundation
import Combine
import Foundation
import SharedCore
import UIKit

@MainActor
final class PlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var state = "Idle"
    @Published private(set) var errorMessage: String?
    @Published private(set) var seconds = 0.0
    @Published private(set) var appliedResumeSeconds = 0.0
    @Published private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published private(set) var subtitleOptions: [AVMediaSelectionOption] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var notifications: [NSObjectProtocol] = []
    private var loading: Task<Void, Never>?
    private var generation = UUID()
    private var pendingResumeSeconds: Double?
    private var wantsToPlay = false
    private var sourceExpiresAtMs: Int64?
    private let lifecycleCenter: NotificationCenter
    private let audioSession: PlaybackAudioSession
    private let audioOwner = UUID()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isForeground = true
    private var isInterrupted = false
    var onProgressSample: ((Double, Double, Bool) -> Void)?

    init(notificationCenter: NotificationCenter = .default, audioSession: PlaybackAudioSession? = nil) {
        lifecycleCenter = notificationCenter
        self.audioSession = audioSession ?? SystemPlaybackAudioSession.shared
        isForeground = UIApplication.shared.applicationState != .background
        observeLifecycle()
    }

    private func observeLifecycle() {
        lifecycleObservers = [
            lifecycleCenter.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] event in
                let raw = (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    guard let self, let raw, let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    if kind == .began {
                        self.isInterrupted = true
                        if self.player.currentItem != nil {
                            self.pause()
                            LocalDiagnostics.shared.record(category: .interruption, event: .interrupted)
                        }
                    } else {
                        self.isInterrupted = false
                        // Playback never resumes merely because another app finished interrupting.
                        LocalDiagnostics.shared.record(category: .interruption, event: .interruptionEnded)
                    }
                }
            },
            lifecycleCenter.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] event in
                let raw = (event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    guard let self, raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                          self.player.currentItem != nil else { return }
                    self.pause()
                    LocalDiagnostics.shared.record(category: .interruption, event: .routeChanged, code: Int(raw ?? 0))
                }
            },
            lifecycleCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isForeground = false
                    self.pause()
                    LocalDiagnostics.shared.record(category: .lifecycle, event: .backgrounded)
                }
            },
            lifecycleCenter.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isForeground = true
                    LocalDiagnostics.shared.record(category: .lifecycle, event: .foregrounded)
                }
            },
            lifecycleCenter.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.player.currentItem != nil else { return }
                    LocalDiagnostics.shared.record(category: .lifecycle, event: .memoryWarning)
                    self.stop()
                }
            }
        ]
    }

    /// Uses documented AVFoundation options only; unsupported provider requirements fail before fetching.
    @discardableResult
    func load(source: PlaybackSource, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), resumeSeconds: Double = 0) -> Bool {
        stop()
        guard let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            fail("The provider returned an invalid media URL."); return false
        }
        if let reason = MediaSourcePolicy.shared.appleUnsupportedReason(source: source, nowMs: nowMs) {
            fail(reason); return false
        }
        var cookies: [HTTPCookie] = []
        for value in source.cookies {
            if let expires = value.expiresAtMs, expires.int64Value <= nowMs {
                fail("A required playback cookie expired. Resolve the source again."); return false
            }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: value.name, .value: value.value, .domain: value.domain, .path: value.path
            ]
            if value.secure { properties[.secure] = "TRUE" }
            if let expires = value.expiresAtMs { properties[.expires] = Date(timeIntervalSince1970: Double(expires.int64Value) / 1_000) }
            guard let cookie = HTTPCookie(properties: properties), Self.cookie(cookie, appliesTo: url) else {
                fail("A required cookie does not apply to this media URL; cross-host cookie requirements are unsupported."); return false
            }
            cookies.append(cookie)
        }
        load(url, headers: source.headers, cookies: cookies, resumeSeconds: resumeSeconds)
        if errorMessage == nil {
            sourceExpiresAtMs = ([source.expiresAtMs?.int64Value] + source.cookies.map { $0.expiresAtMs?.int64Value }).compactMap { $0 }.min()
        }
        return errorMessage == nil
    }

    private static func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
        guard let host = url.host?.lowercased(), cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let path = url.path.isEmpty ? "/" : url.path
        let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        return (host == domain || host.hasSuffix("." + domain)) && pathMatches && (!cookie.isSecure || url.scheme == "https")
    }

    // AVFoundation has a public cookie option, but no public arbitrary HTTP header API.
    // Refuse unsupported headers rather than silently dropping provider requirements.
    func load(_ url: URL, headers: [String: String] = [:], cookies: [HTTPCookie] = [], resumeSeconds: Double = 0) {
        stop()
        guard ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
            fail("Use an HTTPS, HTTP, or local file URL.")
            return
        }
        guard headers.keys.allSatisfy({ $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) else {
            fail("Arbitrary request headers are unsupported by this AVPlayer prototype.")
            return
        }
        errorMessage = nil
        state = "Loading"
        pendingResumeSeconds = resumeSeconds.isFinite && resumeSeconds > 0 ? resumeSeconds : nil
        let token = generation
        let scopedCookies = cookies.filter { Self.cookie($0, appliesTo: url) }
        var options: [String: Any] = [AVURLAssetHTTPCookiesKey: scopedCookies]
        if let agent = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
            options[AVURLAssetHTTPUserAgentKey] = agent
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if item.status == .failed {
                        let error = item.error as NSError?
                        self.fail("Media load failed: \(error?.domain ?? "unknown") code \(error?.code ?? 0).", code: error?.code)
                    }
                    else if item.status == .readyToPlay {
                        if let resume = self.pendingResumeSeconds {
                            let duration = item.duration.seconds
                            let target = duration.isFinite && duration > 0 ? min(resume, max(0, duration - 0.1)) : resume
                            self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                                Task { @MainActor [weak self] in
                                    guard let self, self.generation == token else { return }
                                    guard finished else { self.pendingResumeSeconds = nil; self.fail("The saved playback position could not be restored."); return }
                                    self.pendingResumeSeconds = nil
                                    self.seconds = target
                                    self.appliedResumeSeconds = target
                                    if self.wantsToPlay { self.play() }
                                    else { self.state = "Paused" }
                                }
                            }
                        } else { self.state = self.player.rate > 0 ? "Playing" : "Ready" }
                    }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.errorMessage == nil else { return }
                    switch player.timeControlStatus {
                    case .playing: self.state = "Playing"
                    case .waitingToPlayAtSpecifiedRate: self.state = "Buffering"
                    case .paused:
                        if self.state != "Ended" { self.state = "Paused" }
                        self.emitProgress(immediate: true)
                    @unknown default: self.state = "Unknown"
                    }
                }
            }
        ]
        notifications = [
            NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.wantsToPlay = false
                    self.state = "Ended"
                    self.emitProgress(immediate: true)
                    self.audioSession.deactivate(owner: self.audioOwner)
                }
            },
            NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.wantsToPlay, self.errorMessage == nil else { return }
                    self.state = "Buffering"
                    self.emitProgress(immediate: true)
                    LocalDiagnostics.shared.record(category: .playback, event: .playbackStalled)
                }
            },
            NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                let message = "Playback failed: \(error?.domain ?? "unknown") code \(error?.code ?? 0)."
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail(message, code: error?.code)
                }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.seconds = time.seconds.isFinite ? time.seconds : 0
                self.emitProgress(immediate: false)
            }
        }
        loading = Task { [weak self] in
            do {
                let audio = try await asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.audioGroup = audio
                self.subtitleGroup = subtitles
                self.audioOptions = audio?.options ?? []
                self.subtitleOptions = subtitles?.options ?? []
            } catch {
                // Playback status reports load failures; missing optional track metadata is not fatal.
            }
        }
    }

    func play() {
        guard isForeground, !isInterrupted, player.currentItem != nil else {
            wantsToPlay = false
            return
        }
        if let expiry = sourceExpiresAtMs, expiry <= Int64(Date().timeIntervalSince1970 * 1_000) {
            fail("The playback source expired. Resolve it again before playing.")
            return
        }
        wantsToPlay = true
        if pendingResumeSeconds == nil {
            do {
                try audioSession.activate(owner: audioOwner, superseded: { [weak self] in self?.pause() })
                player.play()
            } catch {
                LocalDiagnostics.shared.record(category: .playback, event: .audioSessionFailed, code: (error as NSError).code)
                fail("Audio output is unavailable. Reload the media and try again.")
            }
        }
    }
    func pause() {
        wantsToPlay = false
        player.pause()
        emitProgress(immediate: true)
        audioSession.deactivate(owner: audioOwner)
    }

    private func emitProgress(immediate: Bool) {
        guard errorMessage == nil, pendingResumeSeconds == nil, let item = player.currentItem, item.status == .readyToPlay else { return }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        guard position.isFinite && position >= 0 else { return }
        onProgressSample?(position, duration.isFinite && duration > 0 ? duration : 0, immediate)
    }
    func seek(by delta: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite, delta.isFinite else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        let target = duration.isFinite ? min(max(0, now + delta), duration) : max(0, now + delta)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func selectAudio(_ option: AVMediaSelectionOption) {
        if let audioGroup { player.currentItem?.select(option, in: audioGroup) }
    }
    func selectSubtitle(_ option: AVMediaSelectionOption?) {
        if let subtitleGroup { player.currentItem?.select(option, in: subtitleGroup) }
    }
    func stop() {
        let releasedItem = player.currentItem != nil
        emitProgress(immediate: true)
        wantsToPlay = false
        sourceExpiresAtMs = nil
        pendingResumeSeconds = nil
        generation = UUID()
        loading?.cancel()
        loading = nil
        observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.currentItem?.asset.cancelLoading()
        player.replaceCurrentItem(with: nil)
        audioSession.deactivate(owner: audioOwner)
        if releasedItem { LocalDiagnostics.shared.record(category: .lifecycle, event: .playerReleased) }
        audioGroup = nil
        subtitleGroup = nil
        audioOptions = []
        subtitleOptions = []
        seconds = 0
        appliedResumeSeconds = 0
        errorMessage = nil
        state = "Idle"
    }
    private func fail(_ message: String, code: Int? = nil) {
        wantsToPlay = false
        player.pause()
        audioSession.deactivate(owner: audioOwner)
        errorMessage = message
        state = "Error"
        LocalDiagnostics.shared.record(category: .playback, event: .initializationFailed, code: code)
    }

    deinit {
        loading?.cancel()
        lifecycleObservers.forEach(lifecycleCenter.removeObserver)
        notifications.forEach(NotificationCenter.default.removeObserver)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.currentItem?.asset.cancelLoading()
        player.replaceCurrentItem(with: nil)
        let session = audioSession
        let owner = audioOwner
        Task { @MainActor in session.deactivate(owner: owner) }
    }
}

@MainActor
protocol PlaybackAudioSession: AnyObject {
    func activate(owner: UUID, superseded: @escaping () -> Void) throws
    func deactivate(owner: UUID)
}

/// Only the current player owns audio-session activation; idle players cannot silence another.
@MainActor
final class SystemPlaybackAudioSession: PlaybackAudioSession {
    static let shared = SystemPlaybackAudioSession()
    private var activeOwner: UUID?
    private var supersede: (() -> Void)?

    func activate(owner: UUID, superseded: @escaping () -> Void) throws {
        guard activeOwner != owner else { return }
        supersede?()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)
        activeOwner = owner
        supersede = superseded
    }

    func deactivate(owner: UUID) {
        guard activeOwner == owner else { return }
        activeOwner = nil
        supersede = nil
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { LocalDiagnostics.shared.record(category: .playback, event: .audioSessionFailed, code: (error as NSError).code) }
    }
}
