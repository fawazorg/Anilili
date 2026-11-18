import AVFoundation
import Combine
import Foundation
import SharedCore
import UIKit

/// Native transport only. Queue, durable states and stale-session validation are Kotlin rules.
@MainActor
final class OfflineDownloadEngine: NSObject, ObservableObject {
    static let shared = OfflineDownloadEngine()
    static let backgroundIdentifier = "org.anilili.playbackpoc.offline-hls"
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var errorMessage: String?
    private(set) var store: OfflineDownloadStore
    private let repository: DownloadRepository
    private let allowLoopback: Bool
    private let diskSpace: () -> Int64
    private let identifier: String
    private let now: () -> Int64
    private var sources: [String: PlaybackSource] = [:]
    private var resumeData: [String: (PlaybackSource, Data)] = [:]
    private var jobs: [Int: Job] = [:]
    private var hlsFractions: [String: Double] = [:]
    private var preparing: [String: (DownloadSession, AVURLAsset)] = [:]
    private var suspendedHLS: [String: Job] = [:]
    private var restored = false
    private var foreground = true
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundCompletion: (() -> Void)?
    private var backgroundEventsFinished = false
    private var finalizing: Set<ObjectIdentifier> = []
    private var isShutdown = false
    private lazy var progressive = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    private lazy var hls: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()
    private struct Job {
        let session: DownloadSession
        let key: String
        let task: URLSessionTask
        var profile: PlaybackSource? = nil
        var sequence: Int64 = 0
        var stagedURL: URL?
    }
    private struct Descriptor: Codable {
        let provider: String; let anime: String; let episode: String; let generation: Int64; let key: String
        init(session: DownloadSession, key: String) {
            provider = session.identity.providerId; anime = session.identity.animeId
            episode = session.identity.episodeId; generation = session.generation; self.key = key
        }
        var session: DownloadSession {
            DownloadSession(identity: DownloadIdentity(providerId: provider, animeId: anime, episodeId: episode), generation: generation)
        }
    }

    init(store: OfflineDownloadStore = OfflineDownloadStore(), allowLoopback: Bool = false,
         backgroundIdentifier: String = OfflineDownloadEngine.backgroundIdentifier,
         diskSpace: (() -> Int64)? = nil, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store; self.allowLoopback = allowLoopback; identifier = backgroundIdentifier
        self.diskSpace = diskSpace ?? { store.availableBytes() }; self.now = now
        repository = DownloadRepository(storage: store)
        super.init()
        foreground = UIApplication.shared.applicationState != .background
        refresh()
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.foreground = true; self?.pump() }
            }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pauseForegroundDownloads() }
            }
        restoreTasks()
    }
    private func id(_ value: DownloadIdentity) -> String {
        [value.providerId, value.animeId, value.episodeId].map { "\($0.utf8.count):\($0)" }.joined()
    }
    private func same(_ a: DownloadIdentity, _ b: DownloadIdentity) -> Bool { id(a) == id(b) }
    func refresh() {
        let result = repository.snapshot(); records = result.records
        if let error = result.error { errorMessage = error }
    }
    var storageUsage: Int64 {
        records.filter { $0.state == .completed }.reduce(0) { total, row in
            row.bytesDownloaded > Int64.max - total ? Int64.max : total + row.bytesDownloaded
        }
    }
    func progressFraction(record: DownloadRecord) -> Double? {
        if record.state == .completed { return 1 }
        if record.format == .hls { return hlsFractions[id(record.identity)] }
        return record.totalBytes > 0 ? min(1, Double(record.bytesDownloaded) / Double(record.totalBytes)) : nil
    }
    private func apply(_ result: DownloadResult) -> Bool {
        records = result.records
        if let error = result.error { errorMessage = error }
        return result.accepted
    }
    @discardableResult
    func download(identity: DownloadIdentity, title: String, episodeTitle: String, source: PlaybackSource,
                  episodeNumber: Int32 = 1) -> Bool {
        errorMessage = nil
        guard source.episodeId == identity.episodeId else { errorMessage = "The resolved media belongs to a different episode."; return false }
        guard valid(source) else { return false }
        if let current = records.first(where: { same($0.identity, identity) }) {
            guard current.format == source.format else {
                errorMessage = "The provider changed media format. Delete the old download entry before downloading again."; return false
            }
            guard current.state != .completed && current.state != .downloading && current.state != .queued else {
                errorMessage = "This episode is already downloaded or queued."; return false
            }
            guard apply(repository.retry(identity: identity, nowMs: now())) else { return false }
        } else {
            guard apply(repository.enqueue(identity: identity, title: title, episodeTitle: episodeTitle,
                format: source.format, nowMs: now(), episodeNumber: episodeNumber)) else { return false }
        }
        sources[id(identity)] = source
        pump()
        return true
    }
    private func valid(_ source: PlaybackSource) -> Bool {
        guard MediaSourcePolicy.shared.validUrl(value: source.url, allowFixtures: false),
              MediaSourcePolicy.shared.validHeaders(headers: source.headers),
              let url = URL(string: source.url), url.host != nil, url.user == nil, url.password == nil,
              url.scheme == "https" || (allowLoopback && url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")) else {
            errorMessage = "Downloads require HTTPS; only explicit test transports allow loopback HTTP."; return false
        }
        if let reason = MediaSourcePolicy.shared.appleUnsupportedReason(source: source, nowMs: now()) {
            errorMessage = reason; return false
        }
        guard source.cookies.allSatisfy({ cookie in
            let host = url.host?.lowercased() ?? ""
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) &&
                (cookie.expiresAtMs?.int64Value ?? Int64.max) > now() && (!cookie.secure || url.scheme == "https")
        }) else { errorMessage = "A required download cookie is expired or outside its host scope."; return false }
        guard cookies(source, url: url).count == source.cookies.count else {
            errorMessage = "A required download cookie is outside its path scope or invalid."; return false
        }
        return true
    }
    private func pump() {
        guard !isShutdown, restored, jobs.isEmpty, preparing.isEmpty else { return }
        guard let record = records.first(where: { $0.state == .queued && sources[id($0.identity)] != nil }),
              let source = sources[id(record.identity)] else { return }
        guard source.format == .hls || foreground else { return }
        let start = repository.begin(identity: record.identity, nowMs: now())
        guard apply(start), let session = start.session else { return }
        guard valid(source) else { _ = apply(repository.fail(session: session, kind: .expired, nowMs: now())); pump(); return }
        guard diskSpace() > 8 * 1024 * 1024 else {
            _ = apply(repository.fail(session: session, kind: .noSpace, nowMs: now()))
            errorMessage = "There is not enough free space to download this episode."; pump(); return
        }
        if let paused = suspendedHLS.removeValue(forKey: id(record.identity)) {
            if paused.task.state == .suspended,
               paused.profile == source {
                let task = paused.task
                task.taskDescription = String(data: try! JSONEncoder().encode(Descriptor(session: session, key: paused.key)), encoding: .utf8)
                jobs[task.taskIdentifier] = Job(session: session, key: paused.key, task: task, profile: source, stagedURL: paused.stagedURL)
                task.resume(); return
            }
            paused.task.cancel(); try? store.remove(key: paused.key)
        }
        let key = UUID().uuidString + (source.format == .mp4 ? ".mp4" : ".movpkg")
        let task: URLSessionTask
        if source.format == .mp4 {
            var request = URLRequest(url: URL(string: source.url)!)
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 30
            for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
            let cookies = cookies(source, url: request.url!)
            if !cookies.isEmpty { request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie") }
            if let saved = resumeData.removeValue(forKey: id(record.identity)), saved.0 == source {
                task = progressive.downloadTask(withResumeData: saved.1)
            } else { task = progressive.downloadTask(with: request) }
        } else {
            prepareHLS(record: record, source: source, session: session, key: key)
            return
        }
        task.taskDescription = String(data: try! JSONEncoder().encode(Descriptor(session: session, key: key)), encoding: .utf8)
        jobs[task.taskIdentifier] = Job(session: session, key: key, task: task, profile: source)
        task.resume()
    }
    private func prepareHLS(record: DownloadRecord, source: PlaybackSource, session: DownloadSession, key: String) {
        let asset = AVURLAsset(url: URL(string: source.url)!, options: [
            AVURLAssetHTTPUserAgentKey: source.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value ?? "Anilili",
            AVURLAssetHTTPCookiesKey: cookies(source, url: URL(string: source.url)!)])
        let identity = id(record.identity)
        preparing[identity] = (session, asset)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let duration: CMTime
            let protected: Bool
            do {
                duration = try await asset.load(.duration)
                protected = try await asset.load(.hasProtectedContent)
            } catch {
                guard !self.isShutdown, self.preparing[identity]?.0.generation == session.generation else { return }
                self.preparing.removeValue(forKey: identity)
                _ = self.apply(self.repository.fail(session: session, kind: .network, nowMs: self.now()))
                self.errorMessage = "HLS metadata could not be loaded. Check the connection and resolve the episode again."
                self.pump(); return
            }
            guard !self.isShutdown, self.preparing[identity]?.0.generation == session.generation else { return }
            self.preparing.removeValue(forKey: identity)
            guard self.records.contains(where: { self.same($0.identity, record.identity) && $0.generation == session.generation && $0.state == .downloading }) else { self.pump(); return }
            guard duration.seconds.isFinite, duration.seconds > 0, protected == false else {
                _ = self.apply(self.repository.fail(session: session, kind: .unsupported, nowMs: self.now()))
                self.errorMessage = "Only finite, unprotected HLS video-on-demand can be downloaded."
                self.pump(); return
            }
            guard self.valid(source) else {
                _ = self.apply(self.repository.fail(session: session, kind: .expired, nowMs: self.now())); self.pump(); return
            }
            let config = AVAssetDownloadConfiguration(asset: asset, title: record.title + " · " + record.episodeTitle)
            let task = self.hls.makeAssetDownloadTask(downloadConfiguration: config)
            task.taskDescription = String(data: try! JSONEncoder().encode(Descriptor(session: session, key: key)), encoding: .utf8)
            self.jobs[task.taskIdentifier] = Job(session: session, key: key, task: task, profile: source)
            task.resume()
        }
    }
    private func cookies(_ source: PlaybackSource, url: URL) -> [HTTPCookie] {
        source.cookies.compactMap { value in
            var properties: [HTTPCookiePropertyKey: Any] = [.name: value.name, .value: value.value,
                .domain: value.domain, .path: value.path]
            if value.secure { properties[.secure] = "TRUE" }
            if let expiry = value.expiresAtMs { properties[.expires] = Date(timeIntervalSince1970: Double(expiry.int64Value) / 1000) }
            guard url.path == value.path || url.path.hasPrefix(value.path.hasSuffix("/") ? value.path : value.path + "/") else { return nil }
            return HTTPCookie(properties: properties)
        }
    }
    func pause(record: DownloadRecord) {
        guard apply(repository.pause(identity: record.identity, nowMs: now())) else { return }
        if let pending = preparing.removeValue(forKey: id(record.identity)) { pending.1.cancelLoading() }
        if let job = jobs.values.first(where: { same($0.session.identity, record.identity) }) {
            jobs.removeValue(forKey: job.task.taskIdentifier)
            if let task = job.task as? URLSessionDownloadTask {
                let source = job.profile
                let generation = records.first(where: { same($0.identity, record.identity) })?.generation
                task.cancel { [weak self] data in
                    Task { @MainActor [weak self] in
                        guard let self, let data, let source,
                              self.records.contains(where: { self.same($0.identity, record.identity) && $0.state == .paused && $0.generation == generation }) else { return }
                        self.resumeData[self.id(record.identity)] = (source, data)
                    }
                }
            } else {
                job.task.suspend()
                suspendedHLS[id(record.identity)] = job
            }
        }
        pump()
    }
    @discardableResult func resume(record: DownloadRecord) -> Bool {
        foreground = UIApplication.shared.applicationState != .background
        guard let source = sources[id(record.identity)] else {
            errorMessage = "Open this episode and resolve its source again to resume after restarting the app."; return false
        }
        return download(identity: record.identity, title: record.title, episodeTitle: record.episodeTitle,
                        source: source, episodeNumber: record.episodeNumber)
    }
    func cancel(record: DownloadRecord) {
        var matching = jobs.values.filter { same($0.session.identity, record.identity) }
        if let paused = suspendedHLS[id(record.identity)] { matching.append(paused) }
        guard apply(repository.cancel(identity: record.identity, nowMs: now())) else { return }
        suspendedHLS.removeValue(forKey: id(record.identity))
        if let pending = preparing.removeValue(forKey: id(record.identity)) { pending.1.cancelLoading() }
        sources.removeValue(forKey: id(record.identity)); resumeData.removeValue(forKey: id(record.identity))
        for job in matching {
            if jobs[job.task.taskIdentifier]?.task === job.task { jobs.removeValue(forKey: job.task.taskIdentifier) }
            job.task.cancel()
            try? store.remove(key: job.key)
        }
        pump()
    }
    func delete(record: DownloadRecord) {
        refresh()
        guard let current = records.first(where: { same($0.identity, record.identity) }) else { return }
        if current.state != .completed && current.state != .cancelled {
            cancel(record: current)
            guard records.contains(where: { same($0.identity, current.identity) && $0.state == .cancelled }) else { return }
        }
        do {
            if let key = current.localMediaKey { try store.remove(key: key) }
            _ = apply(repository.remove(identity: current.identity))
            sources.removeValue(forKey: id(current.identity)); resumeData.removeValue(forKey: id(current.identity))
        } catch { errorMessage = "Downloaded media could not be deleted safely. Please retry." }
    }
    /// User-facing verification hashes progressive media off the main actor.
    func validatedLocalURL(identity: DownloadIdentity) async -> URL? {
        refresh()
        guard let record = records.first(where: { same($0.identity, identity) && $0.state == .completed }),
              let key = record.localMediaKey else { return nil }
        guard record.format == .mp4 else { return localURL(identity: identity) }
        let files = store
        let expectedBytes = record.bytesDownloaded
        let url = await Task.detached(priority: .userInitiated) {
            files.progressiveURL(key: key, expectedBytes: expectedBytes)
        }.value
        guard !Task.isCancelled else { return nil }
        refresh()
        guard records.contains(where: { same($0.identity, identity) && $0.generation == record.generation && $0.localMediaKey == key && $0.state == .completed }) else { return nil }
        return resolveAvailability(record: record, url: url)
    }
    func localURL(identity: DownloadIdentity) -> URL? {
        refresh()
        guard let record = records.first(where: { same($0.identity, identity) && $0.state == .completed }), let key = record.localMediaKey else { return nil }
        let url: URL?
        if record.format == .mp4 { url = store.progressiveURL(key: key, expectedBytes: record.bytesDownloaded) }
        else {
            let package = store.hlsURL(key: key)
            url = package.flatMap { AVURLAsset(url: $0).assetCache?.isPlayableOffline == true ? $0 : nil }
        }
        return resolveAvailability(record: record, url: url)
    }
    private func resolveAvailability(record: DownloadRecord, url: URL?) -> URL? {
        guard let key = record.localMediaKey else { return nil }
        guard let url else {
            let present = store.mediaExists(key: key)
            do { try store.remove(key: key) }
            catch {
                errorMessage = "Damaged media could not be cleaned up safely. Use Delete to retry; its metadata was preserved."; return nil
            }
            _ = apply(repository.markUnavailable(identity: record.identity, kind: present ? .corrupt : .missing, nowMs: now()))
            errorMessage = "The downloaded media is missing or damaged. Resolve the episode online to retry."; return nil
        }
        return url
    }
    func pauseForegroundDownloads() {
        foreground = false
        for record in records where record.format == .mp4 && (record.state == .queued || record.state == .downloading) { pause(record: record) }
    }
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) -> Bool {
        guard identifier == self.identifier else { return false }
        backgroundCompletion = completion
        _ = hls
        finishBackgroundEventsIfReady()
        return true
    }
    private func finishBackgroundEventsIfReady() {
        guard backgroundEventsFinished, finalizing.isEmpty, let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        backgroundEventsFinished = false
        completion()
    }
    private func restoreTasks() {
        let interrupted = Set(records.filter { $0.state == .queued || $0.state == .downloading }.map { id($0.identity) })
        hls.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var active = Set<String>()
                for task in tasks {
                    guard let text = task.taskDescription, let data = text.data(using: .utf8),
                          let item = try? JSONDecoder().decode(Descriptor.self, from: data) else { task.cancel(); continue }
                    if task.state == .suspended, self.records.contains(where: { self.same($0.identity, item.session.identity) && $0.generation > item.generation && $0.state == .paused }) {
                        self.suspendedHLS[self.id(item.session.identity)] = Job(session: item.session, key: item.key, task: task)
                        continue
                    }
                    guard self.records.contains(where: { self.same($0.identity, item.session.identity) && $0.generation == item.generation && $0.state == .downloading }) else { task.cancel(); continue }
                    self.jobs[task.taskIdentifier] = Job(session: item.session, key: item.key, task: task)
                    active.insert(self.id(item.session.identity))
                }
                for record in self.records where interrupted.contains(self.id(record.identity)) && (record.state == .queued || record.state == .downloading) && !active.contains(self.id(record.identity)) {
                    _ = self.apply(self.repository.pause(identity: record.identity, nowMs: self.now()))
                }
                self.restored = true; self.pump()
            }
        }
    }
    func shutdown() {
        isShutdown = true
        for (_, value) in preparing {
            value.1.cancelLoading()
            _ = apply(repository.pause(identity: value.0.identity, nowMs: now()))
        }
        preparing.removeAll()
        pauseForegroundDownloads()
        progressive.invalidateAndCancel()
        hls.finishTasksAndInvalidate()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        backgroundObserver = nil; foregroundObserver = nil
    }
    private func failed(_ task: URLSessionTask, kind: DownloadErrorKind, message: String) {
        guard let job = jobs[task.taskIdentifier], job.task === task else { return }
        jobs.removeValue(forKey: task.taskIdentifier)
        _ = apply(repository.fail(session: job.session, kind: kind, nowMs: now()))
        try? store.remove(key: job.key)
        errorMessage = message
        pump()
    }
}

extension OfflineDownloadEngine: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard var job = jobs[downloadTask.taskIdentifier], job.task === downloadTask else { return }
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 || response.statusCode == 206 else {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                let expired = (sources[id(job.session.identity)]?.expiresAtMs?.int64Value ?? Int64.max) <= now()
                failed(downloadTask, kind: expired ? .expired : (status == 401 || status == 403 ? .authentication : .http),
                       message: "Download server returned HTTP \(status). Resolve the source and retry.")
                return
            }
            do {
                job.stagedURL = try store.installProgressive(temporary: location, key: job.key)
                jobs[downloadTask.taskIdentifier] = job
            } catch { failed(downloadTask, kind: .storage, message: "Downloaded media could not be stored.") }
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                               totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard var job = jobs[downloadTask.taskIdentifier], job.task === downloadTask else { return }
            let reserve: Int64 = 4 * 1024 * 1024
            let available = diskSpace()
            let remaining = totalBytesExpectedToWrite > 0 ? max(0, totalBytesExpectedToWrite - max(0, totalBytesWritten)) : 0
            if available < reserve || available - reserve < remaining {
                downloadTask.cancel(); failed(downloadTask, kind: .noSpace, message: "Not enough free storage to finish this download."); return
            }
            job.sequence += 1; jobs[downloadTask.taskIdentifier] = job
            _ = apply(repository.progress(session: job.session, bytesDownloaded: totalBytesWritten,
                totalBytes: max(0, totalBytesExpectedToWrite), sequence: job.sequence, nowMs: now()))
        }
    }
    @available(iOS 18.0, *)
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        // Both callbacks only register Apple's location; didComplete validates offline availability.
        self.urlSession(session, assetDownloadTask: assetDownloadTask, didFinishDownloadingTo: location)
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard var job = jobs[assetDownloadTask.taskIdentifier], job.task === assetDownloadTask else {
                if var paused = suspendedHLS.values.first(where: { $0.task === assetDownloadTask }) {
                    do { try store.rememberHLS(location: location, key: paused.key); paused.stagedURL = location; suspendedHLS[id(paused.session.identity)] = paused }
                    catch { errorMessage = "The paused HLS package could not be registered safely." }
                    return
                }
                if let description = assetDownloadTask.taskDescription, let data = description.data(using: .utf8),
                   let item = try? JSONDecoder().decode(Descriptor.self, from: data) {
                    if !records.contains(where: { $0.state == .completed && $0.localMediaKey == item.key }) {
                        try? store.rememberHLS(location: location, key: item.key)
                        try? store.remove(key: item.key)
                    }
                }
                return
            }
            do { try store.rememberHLS(location: location, key: job.key); job.stagedURL = location; jobs[assetDownloadTask.taskIdentifier] = job }
            catch {
                // Only a fixed category is exposed: no media URLs, package names or credentials.
                let category = (error as? OfflineDownloadStore.HLSLocationFailure)?.rawValue ?? "receiptWriteFailed"
                assetDownloadTask.cancel()
                failed(assetDownloadTask, kind: .storage, message: "The HLS package could not be registered (\(category)).")
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                               totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        MainActor.assumeIsolated {
            guard let job = jobs[assetDownloadTask.taskIdentifier], job.task === assetDownloadTask else { return }
            if diskSpace() < 4 * 1024 * 1024 {
                assetDownloadTask.cancel()
                failed(assetDownloadTask, kind: .noSpace, message: "Not enough free storage to finish this HLS download."); return
            }
            let expected = timeRangeExpectedToLoad.duration.seconds
            let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
            if expected.isFinite && expected > 0 && loaded.isFinite {
                hlsFractions[id(job.session.identity)] = min(1, max(0, loaded / expected)); objectWillChange.send()
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let job = jobs[task.taskIdentifier], job.task === task else { return }
            if let error {
                let native = error as NSError
                let code = native.code
                if let data = native.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   let source = job.profile {
                    resumeData[id(job.session.identity)] = (source, data)
                }
                let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError
                let full = native.domain == NSCocoaErrorDomain && code == NSFileWriteOutOfSpaceError ||
                    underlying?.domain == NSCocoaErrorDomain && underlying?.code == NSFileWriteOutOfSpaceError
                failed(task, kind: full ? .noSpace : (code == NSURLErrorCancelled ? .cancelled : .network),
                       message: "Download interrupted. Resolve the episode and retry.")
                return
            }
            guard let url = job.stagedURL else { failed(task, kind: .corrupt, message: "The server did not produce complete offline media."); return }
            let finalization = ObjectIdentifier(task)
            finalizing.insert(finalization)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.finalizing.remove(finalization)
                    self.finishBackgroundEventsIfReady()
                }
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) == true
                guard self.jobs[task.taskIdentifier]?.session.generation == job.session.generation,
                      self.jobs[task.taskIdentifier]?.task === task else { return }
                let bytes = self.store.size(url)
                let ready = task is AVAssetDownloadTask ? asset.assetCache?.isPlayableOffline == true : self.store.progressiveURL(key: job.key, expectedBytes: bytes, checkFingerprint: false) != nil
                guard playable && ready && bytes > 0 else {
                    self.failed(task, kind: .corrupt, message: "Downloaded media is not playable offline."); return
                }
                if task is URLSessionDownloadTask {
                    let files = self.store
                    let mediaKey = job.key
                    let fingerprint = await Task.detached(priority: .utility) { try? files.calculatedFingerprint(key: mediaKey) }.value
                    guard self.jobs[task.taskIdentifier]?.session.generation == job.session.generation,
                          self.jobs[task.taskIdentifier]?.task === task else { return }
                    guard let fingerprint else {
                        self.failed(task, kind: .storage, message: "Media integrity metadata could not be read."); return
                    }
                    do { try self.store.writeFingerprint(key: job.key, fingerprint: fingerprint) }
                    catch { self.failed(task, kind: .storage, message: "Media integrity metadata could not be saved."); return }
                }
                self.jobs.removeValue(forKey: task.taskIdentifier)
                let accepted = self.apply(self.repository.complete(session: job.session, localMediaKey: job.key, bytesDownloaded: bytes, nowMs: self.now()))
                if !accepted { try? self.store.remove(key: job.key) }
                self.sources.removeValue(forKey: self.id(job.session.identity)); self.resumeData.removeValue(forKey: self.id(job.session.identity))
                self.pump()
            }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.backgroundEventsFinished = true
            self?.finishBackgroundEventsIfReady()
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let previous = response.url, let next = request.url,
              previous.scheme == next.scheme, previous.host == next.host, previous.port == next.port else {
            completionHandler(nil); return
        }
        var nextRequest = request; nextRequest.httpShouldHandleCookies = false; completionHandler(nextRequest)
    }
}
