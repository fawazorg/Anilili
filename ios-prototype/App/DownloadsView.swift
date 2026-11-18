import SwiftUI
import SharedCore

/// A single native player consumes completed local media and the existing shared history rules.
@MainActor
final class OfflinePlaybackModel: ObservableObject {
    let engine: OfflineDownloadEngine
    let playback = PlaybackModel()
    @Published private(set) var isLoading = false
    @Published private(set) var selected: DownloadRecord?
    @Published private(set) var errorMessage: String?
    private var history: WatchHistoryModel?
    private var validationTask: Task<Void, Never>?
    private var validationGeneration = UUID()
    private var pendingIdentity: DownloadIdentity?
    private let historyStorage: WatchHistoryStorage

    init(engine: OfflineDownloadEngine? = nil, historyStorage: WatchHistoryStorage? = nil) {
        self.engine = engine ?? .shared
        self.historyStorage = historyStorage ?? HistoryFileStorage(fileURL: HistoryFileStorage.applicationURL())
    }

    func play(_ record: DownloadRecord) {
        stop()
        isLoading = true
        pendingIdentity = record.identity
        let generation = validationGeneration
        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let local = await self.engine.validatedLocalURL(identity: record.identity)
            guard !Task.isCancelled, self.validationGeneration == generation else { return }
            self.isLoading = false
            self.validationTask = nil
            self.pendingIdentity = nil
            guard let url = local, let anime = Int32(record.identity.animeId) else {
                self.errorMessage = "Local media is unavailable. Resolve the episode again to download a fresh copy."
                return
            }
            let episode = Episode(id: record.identity.episodeId, animeId: anime,
                number: record.episodeNumber, title: record.episodeTitle)
            let history = WatchHistoryModel(storage: self.historyStorage, providerId: record.identity.providerId)
            self.history = history
            let resume = history.begin(episode: episode, animeTitle: record.title)
            self.playback.onProgressSample = { [weak history] position, duration, immediate in
                history?.sample(positionSeconds: position, durationSeconds: duration, immediate: immediate)
            }
            self.selected = record
            self.playback.load(url, resumeSeconds: resume)
            self.playback.play()
        }
    }

    func stop() {
        validationGeneration = UUID()
        validationTask?.cancel()
        validationTask = nil
        pendingIdentity = nil
        isLoading = false
        playback.stop()
        history?.endSession()
        playback.onProgressSample = nil
        history = nil
        selected = nil
        errorMessage = nil
    }

    func background() {
        if isLoading { stop() }
        else { playback.pause() }
    }

    func delete(_ record: DownloadRecord) {
        if selected?.identity == record.identity || pendingIdentity == record.identity { stop() }
        engine.delete(record: record)
    }
}

struct DownloadsView: View {
    @ObservedObject private var engine = OfflineDownloadEngine.shared
    @StateObject private var model = OfflinePlaybackModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Completed media: \(ByteCountFormatter.string(fromByteCount: engine.storageUsage, countStyle: .file))")
                    Text("MP4 downloads pause in the background. HLS uses Apple's native asset downloads. After a restart, resolve the episode again if a fresh source is required.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error = engine.errorMessage { Text(error).foregroundStyle(.red) }
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                }
                if model.isLoading {
                    ProgressView("Checking downloaded media…")
                    Button("Cancel playback preparation") { model.stop() }
                }
                if let selected = model.selected {
                    Section(selected.episodeTitle) {
                        PlayerControls(model: model.playback)
                        Button("Close offline player") { model.stop() }
                            .frame(minHeight: 44).accessibilityIdentifier("downloads.player.close")
                    }
                }
                if engine.records.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                        description: Text("Open an episode's actions in Ani.pm or AniChan and choose Download episode."))
                }
                ForEach(engine.records, id: \.downloadRowID) { record in
                    Section {
                        Text(record.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(record.episodeTitle).fixedSize(horizontal: false, vertical: true)
                        Text(record.state.name.capitalized).accessibilityIdentifier("downloads.state.\(record.downloadRowID)")
                        if record.state == .downloading || record.state == .queued {
                            if let fraction = engine.progressFraction(record: record) {
                                ProgressView(value: fraction)
                            } else { ProgressView("Downloading…") }
                        }
                        if let error = record.failure { Text(error.name.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(.red) }
                        HStack {
                            if record.state == .completed {
                                Button("Play offline") { model.play(record) }
                                    .accessibilityIdentifier("downloads.play.\(record.downloadRowID)")
                            }
                            if record.state == .downloading || record.state == .queued {
                                Button("Pause") { engine.pause(record: record) }
                            }
                            if record.state == .paused || record.state == .failed || record.state == .cancelled {
                                Button(record.state == .paused ? "Resume" : "Retry") { _ = engine.resume(record: record) }
                            }
                            if record.state != .completed && record.state != .cancelled {
                                Button("Cancel") { engine.cancel(record: record) }
                            }
                        }.buttonStyle(.bordered).frame(minHeight: 44)
                        Button("Delete download", role: .destructive) { model.delete(record) }
                            .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("Downloads")
            .accessibilityIdentifier("downloads.list")
            .toolbar { Button("Refresh") { engine.refresh() } }
        }
        .onAppear { engine.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.background(); engine.pauseForegroundDownloads() }
            if phase == .active { engine.refresh() }
        }
        .onDisappear { model.stop() }
    }
}

extension DownloadRecord {
    var downloadRowID: String {
        [identity.providerId, identity.animeId, identity.episodeId].map { "\($0.utf8.count):\($0)" }.joined()
    }
}
