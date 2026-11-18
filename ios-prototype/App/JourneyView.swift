import SwiftUI
import SharedCore

/// One journey instance owns the selected provider and its player until the selection changes.
struct ProviderJourneyView: View {
    @State private var providerId = "demo-v1"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Video provider", selection: $providerId) {
                Text("Demo").tag("demo-v1")
                Text("Ani.pm").tag("anipm")
                Text("AniChan").tag("anichan")
            }.pickerStyle(.segmented).padding(.horizontal)
                .accessibilityIdentifier("journey.provider")
            JourneyView(providerId: providerId).id(providerId)
        }
    }
}

struct JourneyView: View {
    @StateObject private var model: JourneyModel
    init(providerId: String = "demo-v1") {
        _model = StateObject(wrappedValue: JourneyModel(
            history: providerId == "demo-v1" ? WatchHistoryModel.persistent : WatchHistoryModel(
                storage: HistoryFileStorage(fileURL: HistoryFileStorage.applicationURL()), providerId: providerId),
            providerId: providerId))
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $model.path) {
            JourneyCatalogScreen(journey: model, catalog: model.catalogModel, history: model.history)
                .navigationTitle(model.providerTitle)
                .navigationDestination(for: JourneyModel.Route.self) { route in
                    switch route {
                    case .details:
                        JourneyDetailsScreen(journey: model, details: model.detailsModel, history: model.history)
                    case .playback:
                        JourneyPlaybackScreen(journey: model, history: model.history)
                    }
                }
        }
        .task { if !model.hasLoadedCatalog { model.loadCatalog() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.foreground() }
            else if phase == .background { model.background() }
        }
        .onDisappear { model.leaveJourney() }
    }
}

private struct JourneyCatalogScreen: View {
    @ObservedObject var journey: JourneyModel
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var history: WatchHistoryModel

    var body: some View {
        VStack(spacing: 12) {
            Text(journey.isDemo ? "Original generated media · no provider login needed" : "AniList catalog · episode availability is checked with \(journey.providerTitle)")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                TextField(journey.isDemo ? "Search demo titles" : "Search anime titles", text: $catalog.query)
                    .textFieldStyle(.roundedBorder).submitLabel(.search)
                    .onSubmit { journey.loadCatalog() }.accessibilityIdentifier("journey.search")
                    .accessibilityLabel(journey.isDemo ? "Search original demo anime" : "Search anime for \(journey.providerTitle)")
                Button { journey.loadCatalog() } label: { Text("Search").frame(minHeight: 44) }
                    .accessibilityIdentifier("journey.search.submit")
            }.padding(.horizontal)
            if let error = history.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("history.error")
            }
            if !history.continuing.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue Watching").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(history.continuing, id: \.historyRowID) { record in
                        Button { journey.continueWatching(record) } label: {
                            VStack(alignment: .leading) {
                                Text(record.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text("\(record.episodeTitle) · \(Int(record.positionMs / 1_000)) seconds")
                                    .font(.caption)
                            }.frame(minHeight: 44, alignment: .leading)
                        }.accessibilityHint("Resume this episode from its saved position")
                            .accessibilityIdentifier("history.continue.\(record.identity.episodeId)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            if catalog.isLoading {
                ProgressView("Loading catalog…").accessibilityIdentifier("journey.catalog.loading")
                Spacer()
            } else if let error = catalog.errorMessage {
                ContentUnavailableView {
                    Label("Catalog unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button { journey.loadCatalog() } label: { Text("Retry").frame(minHeight: 44) } }
            } else if catalog.items.isEmpty {
                ContentUnavailableView("No results", systemImage: "magnifyingglass", description: Text("Try another title or clear the search."))
            } else {
                List(catalog.items, id: \.id) { media in
                    Button { journey.openAnime(media.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(media.title.preferred).font(.headline).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(media.format ?? (journey.isDemo ? "Original demo" : "Anime")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }.padding(.vertical, 4).frame(minHeight: 44, alignment: .leading)
                    }.accessibilityHint("Show anime details and available episodes")
                        .accessibilityIdentifier("journey.anime.\(media.id)")
                }.accessibilityIdentifier("journey.catalog")
            }
        }
    }
}

private struct JourneyDetailsScreen: View {
    @ObservedObject var journey: JourneyModel
    @ObservedObject var details: CatalogDetailsModel
    @ObservedObject var history: WatchHistoryModel

    var body: some View {
        List {
            if let error = history.errorMessage {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("history.error")
            }
            if details.isLoading {
                ProgressView("Loading anime details…")
            } else if let error = details.errorMessage {
                Text(error).foregroundStyle(.red)
                Button { journey.retryDetails() } label: { Text("Retry details").frame(minHeight: 44) }
            } else if let media = details.media {
                Section {
                    Text(media.title.preferred).font(.title2).accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = media.synopsis { Text(description) }
                    if let episodes = media.episodes { Text("\(episodes.intValue) episodes") }
                }
            }
            if !journey.isDemo {
                Picker("Audio edition", selection: Binding(get: { journey.audio }, set: { journey.setAudio($0) })) {
                    Text("Original / sub").tag("sub")
                    Text("Dub").tag("dub")
                }.accessibilityIdentifier("journey.audio")
            }
            Section {
                if journey.isLoadingEpisodes {
                    ProgressView("Loading episodes…")
                } else if let error = journey.episodesError {
                    Text(error).foregroundStyle(.red)
                    Button { journey.retryDetails() } label: { Text("Retry episodes").frame(minHeight: 44) }
                } else if journey.episodes.isEmpty {
                    Text("No episodes are available for this title.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("journey.episodes.empty")
                } else {
                    ForEach(journey.episodes, id: \.id) { episode in
                        Button { journey.selectEpisode(episode) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Episode \(episode.number) · \(episode.title)").foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let record = history.record(for: episode) {
                                        Text(record.completed ? "Watched" : (record.positionMs > 0 ? "Resume at \(Int(record.positionMs / 1_000)) seconds" : "Unwatched"))
                                            .font(.caption).foregroundStyle(.secondary)
                                            .accessibilityIdentifier("history.status.\(episode.id)")
                                    }

                                }
                                Spacer()
                                if journey.resolvingEpisodeID == episode.id { ProgressView() }
                                else { Image(systemName: "play.circle").accessibilityHidden(true) }
                            }.frame(minHeight: 44, alignment: .leading)
                        }
                        .accessibilityHint("Resolve this episode and begin playback")
                        .disabled(journey.resolvingEpisodeID != nil || journey.requiresSubtitleConsent)
                        .accessibilityIdentifier("journey.episode.\(episode.id)")
                        .contextMenu {
                            Button(history.record(for: episode)?.completed == true ? "Mark unwatched" : "Mark watched") {
                                journey.markEpisode(episode, watched: history.record(for: episode)?.completed != true)
                            }
                        }
                        .swipeActions {
                            Button(history.record(for: episode)?.completed == true ? "Unwatched" : "Watched") {
                                journey.markEpisode(episode, watched: history.record(for: episode)?.completed != true)
                            }
                        }
                    }
                }
                if journey.resolvingEpisodeID != nil {
                    Button { journey.cancelResolution() } label: { Text("Cancel resolution").frame(minHeight: 44) }
                        .accessibilityIdentifier("journey.resolve.cancel")
                }
                if let error = journey.resolutionError {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("journey.resolve.error")
                    Text("Select an episode to retry.").font(.caption)
                }
            } header: { Text("Episodes") } footer: {
                Text(journey.isDemo ? "MP4 is bundled for offline playback. HLS requires the local fixture server. The missing-source and invalid-media episodes demonstrate error handling." : "Catalog titles come from AniList. This provider may not carry the selected title or audio edition. Browser challenges and unsupported playback requirements are reported explicitly.")
            }
        }
        .navigationTitle("Anime details")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("journey.details")
        .safeAreaInset(edge: .bottom) {
            if journey.requiresSubtitleConsent {
                // Keep this decision visible even after selecting an episode in a long list.
                VStack(spacing: 8) {
                    Text("External provider subtitles are unavailable in this player. Embedded HLS tracks remain available. Play without the external subtitles?")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("journey.subtitles.warning")
                    Button { journey.playWithoutExternalSubtitles() } label: {
                        Text("Play without external subtitles").frame(minHeight: 44)
                    }.accessibilityIdentifier("journey.subtitles.confirm")
                    Button { journey.cancelResolution() } label: { Text("Cancel").frame(minHeight: 44) }
                        .accessibilityIdentifier("journey.subtitles.cancel")
                }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
    }
}

private struct JourneyPlaybackScreen: View {
    @ObservedObject var journey: JourneyModel
    @ObservedObject var history: WatchHistoryModel
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(journey.selectedEpisode?.title ?? "Playback").font(.headline)
                if journey.resumeFromSeconds > 0 {
                    Text("Resuming at \(journey.resumeFromSeconds, specifier: "%.1f") seconds")
                        .font(.caption).accessibilityIdentifier("history.resume")
                }
                PlayerControls(model: journey.playback)
                if let error = history.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("history.error")
                }
                if let episode = journey.selectedEpisode {
                    Button { journey.markEpisode(episode, watched: true) } label: { Text("Mark watched").frame(minHeight: 44) }
                        .accessibilityIdentifier("history.mark-watched")
                }
                Button { journey.returnToEpisodes() } label: { Text("Back to episodes").frame(minHeight: 44) }
                    .accessibilityIdentifier("journey.playback.back")
            }.padding()
        }
        .navigationTitle("Episode playback")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("journey.playback")
    }
}
