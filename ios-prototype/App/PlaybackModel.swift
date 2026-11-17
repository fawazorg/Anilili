import AVFoundation
import Combine
import Foundation
import SharedCore

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
    var onProgressSample: ((Double, Double, Bool) -> Void)?

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
                        self.fail("Media load failed: \(error?.domain ?? "unknown") code \(error?.code ?? 0).")
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
                        self.state = "Paused"
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
                    self.state = "Ended"
                    self.emitProgress(immediate: true)
                }
            },
            NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                let message = "Playback failed: \(error?.domain ?? "unknown") code \(error?.code ?? 0)."
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail(message)
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
        if let expiry = sourceExpiresAtMs, expiry <= Int64(Date().timeIntervalSince1970 * 1_000) {
            fail("The playback source expired. Resolve it again before playing.")
            return
        }
        wantsToPlay = true
        if player.currentItem != nil && pendingResumeSeconds == nil { player.play() }
    }
    func pause() { wantsToPlay = false; player.pause(); emitProgress(immediate: true) }

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
        audioGroup = nil
        subtitleGroup = nil
        audioOptions = []
        subtitleOptions = []
        seconds = 0
        appliedResumeSeconds = 0
        errorMessage = nil
        state = "Idle"
    }
    private func fail(_ message: String) { player.pause(); errorMessage = message; state = "Error" }
}
