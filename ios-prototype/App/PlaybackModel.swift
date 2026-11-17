import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var state = "Idle"
    @Published private(set) var errorMessage: String?
    @Published private(set) var seconds = 0.0
    @Published private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published private(set) var subtitleOptions: [AVMediaSelectionOption] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var notifications: [NSObjectProtocol] = []
    private var loading: Task<Void, Never>?
    private var generation = UUID()

    // AVFoundation has a public cookie option, but no public arbitrary HTTP header API.
    // Refuse unsupported headers rather than silently dropping provider requirements.
    func load(_ url: URL, headers: [String: String] = [:], cookies: [HTTPCookie] = []) {
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
        let token = generation
        let scopedCookies = cookies.filter { cookie in
            guard let host = url.host?.lowercased() else { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) && (!cookie.isSecure || url.scheme == "https")
        }
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
                    else if item.status == .readyToPlay { self.state = self.player.rate > 0 ? "Playing" : "Ready" }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.errorMessage == nil else { return }
                    switch player.timeControlStatus {
                    case .playing: self.state = "Playing"
                    case .waitingToPlayAtSpecifiedRate: self.state = "Buffering"
                    case .paused: self.state = "Paused"
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

    func play() { if player.currentItem != nil { player.play() } }
    func pause() { player.pause() }
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
        errorMessage = nil
        state = "Idle"
    }
    private func fail(_ message: String) { player.pause(); errorMessage = message; state = "Error" }
}
