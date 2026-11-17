import AVFoundation
import Combine
import Foundation
import SharedCore

/// Owns one connected journey. Kotlin owns catalog/episode parsing and source resolution.
@MainActor
final class JourneyModel: ObservableObject {
    enum Route: Hashable { case details(Int32), playback(String) }
    @Published var path: [Route] = [] {
        didSet {
            if oldValue.contains(where: { if case .playback = $0 { return true }; return false }) &&
                !path.contains(where: { if case .playback = $0 { return true }; return false }) {
                playback.stop()
                selectedEpisode = nil
            }
            if path.isEmpty && !oldValue.isEmpty { cancelDetails() }
        }
    }
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var isLoadingEpisodes = false
    @Published private(set) var resolvingEpisodeID: String?
    @Published private(set) var episodesError: String?
    @Published private(set) var resolutionError: String?
    @Published private(set) var selectedEpisode: Episode?
    let playback = PlaybackModel()
    let catalogModel: CatalogModel
    let detailsModel: CatalogDetailsModel
    private let episodeClient: EpisodeClient
    private let sourceURL: (String) -> URL?
    private var episodeRequest: CatalogCancellation?
    private var resolutionRequest: CatalogCancellation?
    private var detailsGeneration = UUID()
    private var resolutionGeneration = UUID()
    private var animeID: Int32?
    private(set) var hasLoadedCatalog = false
    private var resumeCatalog = false
    private var resumeDetails = false

    init(transport: CatalogCallbackTransport = DemoJourneyTransport(),
         sourceURL: @escaping (String) -> URL? = JourneyModel.fixtureURL) {
        let catalog = CatalogClient(transport: transport, endpoint: "demo://catalog")
        catalogModel = CatalogModel(client: catalog)
        detailsModel = CatalogDetailsModel(client: catalog)
        episodeClient = EpisodeClient(transport: transport, endpoint: "demo://episodes")
        self.sourceURL = sourceURL
    }

    nonisolated static func fixtureURL(_ address: String) -> URL? {
        guard let url = URL(string: address) else { return nil }
        guard url.scheme == "fixture" else {
            return ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        // Only known original fixtures are admitted; provider URLs cannot name arbitrary files.
        switch address {
        case "fixture://progressive.mp4":
            return Bundle.main.url(forResource: "progressive", withExtension: "mp4", subdirectory: "Fixtures")
        case "fixture://invalid.mp4":
            return Bundle.main.url(forResource: "invalid", withExtension: "mp4", subdirectory: "Fixtures")
        case "fixture://hls/master.m3u8":
            return URL(string: "http://127.0.0.1:8765/hls/master.m3u8")
        default: return nil
        }
    }

    func loadCatalog() {
        hasLoadedCatalog = true
        catalogModel.search(allowEmpty: true)
    }

    func openAnime(_ id: Int32) {
        cancelDetails()
        playback.stop()
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
        episodeRequest = episodeClient.episodes(animeId: id, completion: JourneyEpisodesCompletion { [weak self] episodes, failure in
            Task { @MainActor [weak self] in
                guard let self, self.detailsGeneration == generation else { return }
                self.episodes = episodes ?? []
                self.episodesError = failure?.message
                self.isLoadingEpisodes = false
                self.episodeRequest = nil
            }
        })
    }

    func selectEpisode(_ episode: Episode) {
        // A selection owns the resolver until completion/cancellation; repeated taps do nothing.
        guard let animeID, resolvingEpisodeID == nil, selectedEpisode == nil, episode.animeId == animeID else { return }
        resolutionGeneration = UUID()
        let generation = resolutionGeneration
        resolvingEpisodeID = episode.id
        resolutionError = nil
        resolutionRequest = episodeClient.resolve(animeId: episode.animeId, episodeId: episode.id,
            completion: JourneySourceCompletion { [weak self] source, failure in
                Task { @MainActor [weak self] in
                    guard let self, self.resolutionGeneration == generation else { return }
                    self.resolvingEpisodeID = nil
                    self.resolutionRequest = nil
                    guard let source, failure == nil else {
                        self.resolutionError = failure?.message ?? "No playable source is available."
                        return
                    }
                    guard let url = self.sourceURL(source.url) else {
                        self.resolutionError = "The resolved media is unavailable on this device."
                        return
                    }
                    self.selectedEpisode = episode
                    self.playback.load(url, headers: source.headers)
                    self.path.append(.playback(episode.id))
                    self.playback.play()
                }
            })
    }

    func cancelResolution() {
        resolutionGeneration = UUID()
        resolutionRequest?.cancel()
        resolutionRequest = nil
        resolvingEpisodeID = nil
    }

    func returnToEpisodes() {
        cancelResolution()
        playback.stop()
        selectedEpisode = nil
        path.removeAll { if case .playback = $0 { return true }; return false }
    }

    func background() {
        resumeCatalog = catalogModel.isLoading
        resumeDetails = detailsModel.isLoading || isLoadingEpisodes
        cancelResolution()
        playback.pause()
        cancelDetails()
        catalogModel.cancel()
    }

    func foreground() {
        if resumeCatalog { loadCatalog() }
        if resumeDetails, let animeID, !path.isEmpty { loadDetailsAndEpisodes(animeID) }
        resumeCatalog = false
        resumeDetails = false
    }

    func leaveJourney() {
        background()
        playback.stop()
        selectedEpisode = nil
        path = []
        resumeCatalog = false
        resumeDetails = false
        hasLoadedCatalog = false
    }

    private func cancelDetails() {
        detailsGeneration = UUID()
        detailsModel.cancel()
        episodeRequest?.cancel()
        episodeRequest = nil
        isLoadingEpisodes = false
        cancelResolution()
    }

    deinit {
        episodeRequest?.cancel()
        resolutionRequest?.cancel()
        episodeClient.close()
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
