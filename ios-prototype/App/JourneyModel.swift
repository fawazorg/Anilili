import AVFoundation
import Combine
import Foundation
import SharedCore
import UIKit

/// Owns one connected journey. Kotlin owns catalog/episode parsing and source resolution.
@MainActor
final class JourneyModel: ObservableObject {
    enum Route: Hashable { case details(Int32), playback(String) }
    @Published var path: [Route] = [] {
        didSet {
            if oldValue.contains(where: { if case .playback = $0 { return true }; return false }) &&
                !path.contains(where: { if case .playback = $0 { return true }; return false }) {
                playback.stop()
                history.endSession()
                selectedEpisode = nil
            }
            if path.isEmpty && !oldValue.isEmpty { cancelDetails() }
        }
    }
    let providerId: String
    var isDemo: Bool { providerId == "demo-v1" }
    var providerTitle: String { isDemo ? "Demo catalog" : (providerId == "anipm" ? "Ani.pm" : "AniChan") }
    @Published private(set) var audio = "sub"
    @Published private(set) var requiresSubtitleConsent = false
    private var pendingSubtitleSource: PlaybackSource?
    private var pendingSubtitleEpisode: Episode?
    private var pendingDownload = false
    var subtitleActionTitle: String { pendingDownload ? "Download without external subtitles" : "Play without external subtitles" }
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var isLoadingEpisodes = false
    @Published private(set) var resolvingEpisodeID: String?
    @Published private(set) var episodesError: String?
    @Published private(set) var resolutionError: String?
    @Published private(set) var selectedEpisode: Episode?
    @Published private(set) var resumeFromSeconds = 0.0
    let playback: PlaybackModel
    let downloads: OfflineDownloadEngine
    let history: WatchHistoryModel
    let catalogModel: CatalogModel
    let detailsModel: CatalogDetailsModel
    private let episodeClient: EpisodeClient?
    private let expandedClient: ExpandedProviderClient?
    private let sourceURL: (String) -> URL?
    private var episodeRequest: CatalogCancellation?
    private var resolutionRequest: CatalogCancellation?
    private var localValidationTask: Task<Void, Never>?
    private var detailsGeneration = UUID()
    private var resolutionGeneration = UUID()
    private var animeID: Int32?
    private(set) var hasLoadedCatalog = false
    private var resumeCatalog = false
    private var resumeDetails = false
    private var continueEpisodeID: String?
    private var isBackgrounded = false
    private let notificationCenter: NotificationCenter
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(transport: CatalogCallbackTransport = DemoJourneyTransport(),
         sourceURL: @escaping (String) -> URL? = JourneyModel.fixtureURL,
         history: WatchHistoryModel? = nil, notificationCenter: NotificationCenter = .default,
         providerId: String = "demo-v1", providerTransport: CatalogCallbackTransport? = nil,
         providerBaseURL: String? = nil, embedBaseURL: String? = nil,
         catalogEndpoint: String? = nil, downloads: OfflineDownloadEngine? = nil) {
        precondition(["demo-v1", "anipm", "anichan"].contains(providerId))
        self.downloads = downloads ?? OfflineDownloadEngine.shared
        self.providerId = providerId
        self.notificationCenter = notificationCenter
        playback = PlaybackModel(notificationCenter: notificationCenter)
        let catalogTransport: CatalogCallbackTransport = providerId == "demo-v1" || catalogEndpoint != nil ? transport : URLSessionCatalogTransport()
        let catalog = CatalogClient(transport: catalogTransport,
            endpoint: catalogEndpoint ?? (providerId == "demo-v1" ? "demo://catalog" : "https://graphql.anilist.co"))
        catalogModel = CatalogModel(client: catalog)
        detailsModel = CatalogDetailsModel(client: catalog)
        if providerId == "demo-v1" {
            episodeClient = EpisodeClient(transport: transport, endpoint: "demo://episodes")
            expandedClient = nil
        } else {
            episodeClient = nil
            let native = providerTransport ?? URLSessionCatalogTransport()
            if let base = providerBaseURL, let embed = embedBaseURL {
                expandedClient = ExpandedProviderClient(transport: native, providerId: providerId,
                    baseUrl: base, embedBaseUrl: embed, timeoutMs: 15_000)
            } else {
                expandedClient = ExpandedProviderClient(transport: native, providerId: providerId)
            }
        }
        self.sourceURL = sourceURL
        let history = history ?? WatchHistoryModel(providerId: providerId)
        precondition(history.providerId == providerId, "History must belong to the selected provider")
        self.history = history
        lifecycleObservers = [
            notificationCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.background() }
            },
            notificationCenter.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.foreground() }
            },
            notificationCenter.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cancelResolution()
                    if self.isLoadingEpisodes { self.cancelDetails(); self.episodesError = "Loading was interrupted. Please retry." }
                    self.returnToEpisodes()
                }
            }
        ]
        playback.onProgressSample = { [weak history] position, duration, immediate in
            history?.sample(positionSeconds: position, durationSeconds: duration, immediate: immediate)
        }
    }

    nonisolated static func fixtureURL(_ address: String) -> URL? {
        guard let url = URL(string: address) else { return nil }
        guard url.scheme == "fixture" else {
            return ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        // Only known original fixtures are admitted; provider URLs cannot name arbitrary files.
        switch address {
        case "fixture://progressive.mp4":
            // Restart UI automation can outlast the twelve-second demo before sampling the clock.
            // Only its explicitly isolated launch uses the longer original-media variant.
            let resource = ProcessInfo.processInfo.arguments.contains("--watch-history-ui-test")
                ? "history-resume" : "progressive"
            return Bundle.main.url(forResource: resource, withExtension: "mp4", subdirectory: "Fixtures")
        case "fixture://invalid.mp4":
            return Bundle.main.url(forResource: "invalid", withExtension: "mp4", subdirectory: "Fixtures")
        case "fixture://hls/master.m3u8":
            return URL(string: "http://127.0.0.1:8765/hls/master.m3u8")
        default: return nil
        }
    }

    func loadCatalog() {
        hasLoadedCatalog = true
        history.refresh()
        catalogModel.search(allowEmpty: true)
    }

    func openAnime(_ id: Int32) {
        cancelDetails()
        playback.stop()
        history.endSession()
        selectedEpisode = nil
        animeID = id
        episodes = []
        episodesError = nil
        path = [.details(id)]
        loadDetailsAndEpisodes(id)
    }

    func retryDetails() { if let animeID { loadDetailsAndEpisodes(animeID) } }

    private func loadDetailsAndEpisodes(_ id: Int32) {
        cancelDetails()
        episodesError = nil
        isLoadingEpisodes = true
        let generation = detailsGeneration
        detailsModel.load(id: id)
        let completion = JourneyEpisodesCompletion { [weak self] episodes, failure in
            Task { @MainActor [weak self] in
                guard let self, self.detailsGeneration == generation else { return }
                self.episodes = episodes ?? []
                self.episodesError = failure?.message
                self.isLoadingEpisodes = false
                self.episodeRequest = nil
                if let pending = self.continueEpisodeID {
                    self.continueEpisodeID = nil
                    if let episode = self.episodes.first(where: { $0.id == pending }) { self.selectEpisode(episode) }
                    else if failure == nil { self.resolutionError = "This saved episode is no longer available from the selected provider." }
                }
            }
        }
        if let expandedClient {
            episodeRequest = expandedClient.episodes(animeId: id, audio: audio, completion: completion)
        } else {
            episodeRequest = episodeClient?.episodes(animeId: id, completion: completion)
        }
    }

    func setAudio(_ value: String) {
        guard ["sub", "dub"].contains(value), audio != value else { return }
        returnToEpisodes()
        audio = value
        if let animeID, !path.isEmpty { loadDetailsAndEpisodes(animeID) }
    }

    func downloadIdentity(for episode: Episode) -> DownloadIdentity {
        DownloadIdentity(providerId: providerId, animeId: String(episode.animeId), episodeId: episode.id)
    }

    func downloadEpisode(_ episode: Episode) { resolveEpisode(episode, forDownload: true) }

    func selectEpisode(_ episode: Episode) {
        guard let animeID, resolvingEpisodeID == nil, selectedEpisode == nil,
              !requiresSubtitleConsent, episode.animeId == animeID else { return }
        let identity = downloadIdentity(for: episode)
        if downloads.records.contains(where: { $0.identity == identity && $0.state == .completed }) {
            resolutionGeneration = UUID()
            let generation = resolutionGeneration
            resolvingEpisodeID = episode.id
            localValidationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let local = await self.downloads.validatedLocalURL(identity: identity)
                guard !Task.isCancelled, self.resolutionGeneration == generation else { return }
                self.resolvingEpisodeID = nil
                self.localValidationTask = nil
                if let local { self.startLocalPlayback(url: local, episode: episode) }
                else { self.resolveEpisode(episode, forDownload: false) }
            }
            return
        }
        // A missing local file falls back to ordinary fresh provider resolution.
        resolveEpisode(episode, forDownload: false)
    }

    private func resolveEpisode(_ episode: Episode, forDownload: Bool) {
        // A selection owns the resolver until completion/cancellation; repeated taps do nothing.
        guard let animeID, resolvingEpisodeID == nil, selectedEpisode == nil, !requiresSubtitleConsent, episode.animeId == animeID else { return }
        resolutionGeneration = UUID()
        let generation = resolutionGeneration
        resolvingEpisodeID = episode.id
        resolutionError = nil
        let completion = JourneySourceCompletion { [weak self] source, failure in
                Task { @MainActor [weak self] in
                    guard let self, self.resolutionGeneration == generation else { return }
                    self.resolvingEpisodeID = nil
                    self.resolutionRequest = nil
                    guard let source, failure == nil else {
                        self.resolutionError = failure?.message ?? "No playable source is available."
                        LocalDiagnostics.shared.record(category: .resolution, event: failure?.kind == .timeout ? .timedOut : .resolutionFailed, code: failure.map { Int($0.status) })
                        return
                    }
                    if !self.isDemo && source.subtitleTracks.contains(where: { $0.url != nil }) {
                        self.pendingSubtitleSource = source
                        self.pendingSubtitleEpisode = episode
                        self.pendingDownload = forDownload
                        self.requiresSubtitleConsent = true
                        return
                    }
                    if forDownload { self.enqueueDownload(source: source, episode: episode) }
                    else { self.startPlayback(source: source, episode: episode) }
                }
            }
        if let expandedClient {
            resolutionRequest = expandedClient.resolve(animeId: episode.animeId, episodeId: episode.id,
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000), completion: completion)
        } else {
            resolutionRequest = episodeClient?.resolve(animeId: episode.animeId, episodeId: episode.id, completion: completion)
        }
    }

    /// Consent applies to this selection only. Other unsupported requirements remain enforced.
    func playWithoutExternalSubtitles() {
        guard requiresSubtitleConsent, let source = pendingSubtitleSource,
              let episode = pendingSubtitleEpisode, let expandedClient else { return }
        let download = pendingDownload
        pendingSubtitleSource = nil
        pendingSubtitleEpisode = nil
        pendingDownload = false
        requiresSubtitleConsent = false
        let supported = expandedClient.videoWithoutExternalSubtitles(source: source)
        if download { enqueueDownload(source: supported, episode: episode) }
        else { startPlayback(source: supported, episode: episode) }
    }

    private func enqueueDownload(source: PlaybackSource, episode: Episode) {
        if !downloads.download(identity: downloadIdentity(for: episode), title: animeTitle(for: episode),
            episodeTitle: episode.title, source: source, episodeNumber: episode.number) {
            resolutionError = downloads.errorMessage ?? "The download could not be started."
        }
    }

    private func startLocalPlayback(url: URL, episode: Episode) {
        let resume = history.begin(episode: episode, animeTitle: animeTitle(for: episode))
        resumeFromSeconds = resume
        selectedEpisode = episode
        playback.load(url, resumeSeconds: resume)
        path.append(.playback(episode.id))
        playback.play()
    }

    private func startPlayback(source: PlaybackSource, episode: Episode) {
        guard let url = sourceURL(source.url) else {
            resolutionError = "The resolved media is unavailable on this device."
            return
        }
        if !isDemo, let reason = MediaSourcePolicy.shared.appleUnsupportedReason(
            source: source, nowMs: Int64(Date().timeIntervalSince1970 * 1_000)) {
            resolutionError = reason
            return
        }
        let resume = history.begin(episode: episode, animeTitle: animeTitle(for: episode))
        resumeFromSeconds = resume
        if isDemo {
            // Original demo file URLs are mapped by the existing allowlisted fixture adapter.
            playback.load(url, headers: source.headers, resumeSeconds: resume)
        } else if !playback.load(source: source, resumeSeconds: resume) {
            resolutionError = playback.errorMessage ?? "The resolved media is unsupported."
            playback.stop()
            history.endSession()
            return
        }
        selectedEpisode = episode
        path.append(.playback(episode.id))
        playback.play()
    }

    func continueWatching(_ record: WatchProgress) {
        guard record.identity.providerId == providerId, let id = Int32(record.identity.animeId) else { return }
        if let restoredAudio = expandedClient?.episodeAudio(episodeId: record.identity.episodeId) { audio = restoredAudio }
        openAnime(id)
        continueEpisodeID = record.identity.episodeId
    }

    func markEpisode(_ episode: Episode, watched: Bool) {
        // Save the current clock before the explicit action invalidates its session generation.
        let markingCurrentEpisode = selectedEpisode?.id == episode.id
        if markingCurrentEpisode { playback.pause(); history.endSession() }
        history.mark(episode, animeTitle: animeTitle(for: episode), watched: watched)
        // Marking invalidates the persisted session. A replay must enter through a fresh session.
        if markingCurrentEpisode { returnToEpisodes() }
    }

    private func animeTitle(for episode: Episode) -> String {
        if let media = detailsModel.media, media.id == episode.animeId { return media.title.preferred }
        if let media = catalogModel.items.first(where: { $0.id == episode.animeId }) { return media.title.preferred }
        if let downloaded = downloads.records.first(where: {
            $0.identity.providerId == providerId && $0.identity.animeId == String(episode.animeId) && $0.identity.episodeId == episode.id
        }) { return downloaded.title }
        return history.record(for: episode)?.title ?? "Demo anime"
    }

    func cancelResolution() {
        localValidationTask?.cancel()
        localValidationTask = nil
        pendingDownload = false
        pendingSubtitleSource = nil
        pendingSubtitleEpisode = nil
        requiresSubtitleConsent = false
        resolutionGeneration = UUID()
        resolutionRequest?.cancel()
        resolutionRequest = nil
        resolvingEpisodeID = nil
    }

    func returnToEpisodes() {
        cancelResolution()
        playback.stop()
        history.endSession()
        selectedEpisode = nil
        path.removeAll { if case .playback = $0 { return true }; return false }
    }

    func background() {
        guard !isBackgrounded else { return }
        isBackgrounded = true
        resumeCatalog = catalogModel.isLoading
        resumeDetails = detailsModel.isLoading || isLoadingEpisodes
        cancelResolution()
        playback.pause()
        cancelDetails()
        catalogModel.cancel()
    }

    func foreground() {
        isBackgrounded = false
        if resumeCatalog { loadCatalog() }
        if resumeDetails, let animeID, !path.isEmpty { loadDetailsAndEpisodes(animeID) }
        resumeCatalog = false
        resumeDetails = false
    }

    func leaveJourney() {
        background()
        playback.stop()
        history.endSession()
        selectedEpisode = nil
        path = []
        resumeCatalog = false
        resumeDetails = false
        hasLoadedCatalog = false
        isBackgrounded = false
    }

    private func cancelDetails() {
        detailsGeneration = UUID()
        continueEpisodeID = nil
        detailsModel.cancel()
        episodeRequest?.cancel()
        episodeRequest = nil
        isLoadingEpisodes = false
        cancelResolution()
    }

    deinit {
        lifecycleObservers.forEach(notificationCenter.removeObserver)
        episodeRequest?.cancel()
        resolutionRequest?.cancel()
        localValidationTask?.cancel()
        episodeClient?.close()
        expandedClient?.close()
    }
}

private final class JourneyEpisodesCompletion: NSObject, EpisodeListCompletion {
    let receive: ([Episode]?, CatalogFailure?) -> Void
    init(_ receive: @escaping ([Episode]?, CatalogFailure?) -> Void) { self.receive = receive; super.init() }
    func complete(episodes: [Episode]?, failure: CatalogFailure?) { receive(episodes, failure) }
}
private final class JourneySourceCompletion: NSObject, EpisodeSourceCompletion {
    let receive: (PlaybackSource?, CatalogFailure?) -> Void
    init(_ receive: @escaping (PlaybackSource?, CatalogFailure?) -> Void) { self.receive = receive; super.init() }
    func complete(source: PlaybackSource?, failure: CatalogFailure?) { receive(source, failure) }
}
