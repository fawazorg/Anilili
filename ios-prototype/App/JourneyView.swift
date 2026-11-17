import SwiftUI
import SharedCore

struct JourneyView: View {
    @StateObject private var model = JourneyModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $model.path) {
            JourneyCatalogScreen(journey: model, catalog: model.catalogModel)
                .navigationTitle("Demo catalog")
                .navigationDestination(for: JourneyModel.Route.self) { route in
                    switch route {
                    case .details:
                        JourneyDetailsScreen(journey: model, details: model.detailsModel)
                    case .playback:
                        JourneyPlaybackScreen(journey: model)
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

    var body: some View {
        VStack(spacing: 12) {
            Text("Original generated media · no provider login needed")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                TextField("Search demo titles", text: $catalog.query)
                    .textFieldStyle(.roundedBorder).submitLabel(.search)
                    .onSubmit { journey.loadCatalog() }.accessibilityIdentifier("journey.search")
                Button("Search") { journey.loadCatalog() }
            }.padding(.horizontal)
            if catalog.isLoading {
                ProgressView("Loading catalog…").accessibilityIdentifier("journey.catalog.loading")
                Spacer()
            } else if let error = catalog.errorMessage {
                ContentUnavailableView {
                    Label("Catalog unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("Retry") { journey.loadCatalog() } }
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
                                Text(media.format ?? "Original demo").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("journey.anime.\(media.id)")
                }.accessibilityIdentifier("journey.catalog")
            }
        }
    }
}

private struct JourneyDetailsScreen: View {
    @ObservedObject var journey: JourneyModel
    @ObservedObject var details: CatalogDetailsModel

    var body: some View {
        List {
            if details.isLoading {
                ProgressView("Loading anime details…")
            } else if let error = details.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Retry details") { journey.retryDetails() }
            } else if let media = details.media {
                Section {
                    Text(media.title.preferred).font(.title2).accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = media.synopsis { Text(description) }
                    if let episodes = media.episodes { Text("\(episodes.intValue) episodes") }
                }
            }
            Section {
                if journey.isLoadingEpisodes {
                    ProgressView("Loading episodes…")
                } else if let error = journey.episodesError {
                    Text(error).foregroundStyle(.red)
                    Button("Retry episodes") { journey.retryDetails() }
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

                                }
                                Spacer()
                                if journey.resolvingEpisodeID == episode.id { ProgressView() }
                                else { Image(systemName: "play.circle").accessibilityHidden(true) }
                            }
                        }
                        .disabled(journey.resolvingEpisodeID != nil)
                        .accessibilityIdentifier("journey.episode.\(episode.id)")
                    }
                }
                if journey.resolvingEpisodeID != nil {
                    Button("Cancel resolution") { journey.cancelResolution() }.accessibilityIdentifier("journey.resolve.cancel")
                }
                if let error = journey.resolutionError {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("journey.resolve.error")
                    Text("Select an episode to retry.").font(.caption)
                }
            } header: { Text("Episodes") } footer: {
                Text("MP4 is bundled for offline playback. HLS requires the local fixture server. The missing-source and invalid-media episodes demonstrate error handling.")
            }
        }
        .navigationTitle("Anime details")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("journey.details")
    }
}

private struct JourneyPlaybackScreen: View {
    @ObservedObject var journey: JourneyModel
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(journey.selectedEpisode?.title ?? "Playback").font(.headline)
                PlayerControls(model: journey.playback)
                Button("Back to episodes") { journey.returnToEpisodes() }
                    .accessibilityIdentifier("journey.playback.back")
            }.padding()
        }
        .navigationTitle("Episode playback")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("journey.playback")
    }
}
