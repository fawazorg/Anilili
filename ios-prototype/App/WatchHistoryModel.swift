import Combine
import Foundation
import SharedCore

/// A native presentation/lifecycle adapter. Identity, completion, resume and history ordering are Kotlin rules.
@MainActor
final class WatchHistoryModel: ObservableObject {
    @Published private(set) var records: [WatchProgress] = []
    @Published private(set) var continuing: [WatchProgress] = []
    @Published private(set) var errorMessage: String?
    private let repository: WatchHistoryRepository
    private let saveIntervalMs: Int64
    private let now: () -> Int64
    private var session: WatchSession?
    private var sequence: Int64 = 0
    private var lastSavedAt: Int64 = 0

    init(storage: WatchHistoryStorage = MemoryHistoryStorage(), rules: WatchHistoryRules? = nil, now: @escaping () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }) {
        let policy = rules ?? WatchHistoryRules(
            completionPercent: 90, minDurationMs: 60_000, resumeRewindMs: 3_000, saveIntervalMs: 10_000)
        repository = WatchHistoryRepository(storage: storage, rules: policy)
        saveIntervalMs = max(1, policy.saveIntervalMs)
        self.now = now
        refresh()
    }

    static let persistent = WatchHistoryModel(storage: HistoryFileStorage(fileURL: HistoryFileStorage.applicationURL()))

    func refresh() {
        let all = repository.snapshot()
        errorMessage = all.error
        if all.error != nil { LocalDiagnostics.shared.record(category: .persistence, event: .storageReadFailed) }
        records = all.records
        let recent = repository.continueWatching()
        continuing = recent.records.filter { $0.identity.providerId == "demo-v1" && Int32($0.identity.animeId) != nil }
        if errorMessage == nil { errorMessage = recent.error }
        if recent.error != nil { LocalDiagnostics.shared.record(category: .persistence, event: .storageReadFailed) }
    }

    func record(for episode: Episode) -> WatchProgress? {
        records.first { $0.identity.providerId == "demo-v1" && $0.identity.animeId == String(episode.animeId) && $0.identity.episodeId == episode.id }
    }

    func begin(episode: Episode, animeTitle: String) -> Double {
        session = nil
        let result = repository.beginSession(identity: identity(episode), title: animeTitle,
            episodeTitle: episode.title, nowMs: now())
        errorMessage = result.error
        if result.error != nil { LocalDiagnostics.shared.record(category: .persistence, event: .storageWriteFailed) }
        session = result.session
        sequence = 0
        lastSavedAt = now()
        refresh()
        if let error = result.error { errorMessage = error }
        guard let record = record(for: episode) else { return 0 }
        return Double(repository.resumePosition(record: record)) / 1_000
    }

    func sample(positionSeconds: Double, durationSeconds: Double, immediate: Bool) {
        guard let session else { return }
        let instant = now()
        guard immediate || instant - lastSavedAt >= saveIntervalMs else { return }
        sequence += 1
        let result = repository.update(session: session, positionMs: positionSeconds * 1_000,
            durationMs: durationSeconds * 1_000, nowMs: instant, sequence: sequence)
        if let error = result.error {
            errorMessage = error
            LocalDiagnostics.shared.record(category: .persistence, event: .storageWriteFailed)
            return
        }
        if result.accepted { lastSavedAt = instant }
        refresh()
    }

    func endSession() { session = nil }

    func mark(_ episode: Episode, animeTitle: String, watched: Bool) {
        let result = repository.mark(identity: identity(episode), title: animeTitle,
            episodeTitle: episode.title, watched: watched, nowMs: now())
        errorMessage = result.error
        if result.error != nil { LocalDiagnostics.shared.record(category: .persistence, event: .storageWriteFailed) }
        if result.error == nil { refresh() }
    }

    private func identity(_ episode: Episode) -> WatchIdentity {
        WatchIdentity(providerId: "demo-v1", animeId: String(episode.animeId), episodeId: episode.id)
    }
}

// Only a SwiftUI row key: persisted identity and deduplication remain in Kotlin.
extension WatchProgress {
    var historyRowID: String {
        [identity.providerId, identity.animeId, identity.episodeId]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}
