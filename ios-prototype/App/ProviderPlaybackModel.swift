import Combine
import Foundation
import SharedCore

/// A known AniDB server endpoint is resolved by Kotlin; Swift owns only transport and AVPlayer.
@MainActor
final class ProviderPlaybackModel: ObservableObject {
    let playback = PlaybackModel()
    @Published private(set) var isResolving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var resolvedFormat: String?
    private let resolver: AniDbSourceClient
    private var request: CatalogCancellation?
    private var generation = UUID()
    private var lastEndpoint: String?

    init(transport: CatalogCallbackTransport = URLSessionCatalogTransport()) {
        resolver = AniDbSourceClient(transport: transport)
    }

    func resolveAndPlay(endpoint: String) {
        // A pending resolution owns this player; rapid repeat taps do not start another session.
        guard !isResolving else { return }
        cancel()
        playback.stop()
        errorMessage = nil
        resolvedFormat = nil
        isResolving = true
        lastEndpoint = endpoint
        let token = generation
        request = resolver.resolve(endpoint: endpoint, episodeId: "manual-anidb-source",
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000), completion: ProviderSourceCompletion { [weak self] source, failure in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.request = nil
                    self.isResolving = false
                    guard let source, failure == nil else {
                        self.errorMessage = failure?.message ?? "The provider returned no playable media."
                        return
                    }
                    guard self.playback.load(source: source) else {
                        self.errorMessage = self.playback.errorMessage
                        return
                    }
                    self.resolvedFormat = source.format.name
                    self.playback.play()
                }
            })
    }

    func retry() { if let lastEndpoint { resolveAndPlay(endpoint: lastEndpoint) } }

    func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        isResolving = false
        errorMessage = nil
        resolvedFormat = nil
    }

    func background() { cancel(); playback.pause() }
    func stop() { cancel(); playback.stop() }
    deinit { request?.cancel(); resolver.close() }
}

private final class ProviderSourceCompletion: NSObject, EpisodeSourceCompletion {
    private let receive: (PlaybackSource?, CatalogFailure?) -> Void
    init(_ receive: @escaping (PlaybackSource?, CatalogFailure?) -> Void) { self.receive = receive; super.init() }
    func complete(source: PlaybackSource?, failure: CatalogFailure?) { receive(source, failure) }
}
