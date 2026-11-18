import SwiftUI
import SharedCore

struct CatalogView: View {
    @StateObject private var model = CatalogModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Search anime", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { model.search() }
                        .accessibilityIdentifier("catalog.query")
                    Button { model.search() } label: { Text("Search").frame(minHeight: 44) }
                        .accessibilityIdentifier("catalog.search")
                }.padding(.horizontal)
                if model.isLoading {
                    ProgressView("Searching AniList…").accessibilityIdentifier("catalog.loading")
                    Spacer()
                } else if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("Search unavailable", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button { model.search() } label: { Text("Retry").frame(minHeight: 44) }
                    }.accessibilityIdentifier("catalog.error")
                } else if model.items.isEmpty {
                    ContentUnavailableView(model.hasSearched ? "No results" : "Search AniList", systemImage: "magnifyingglass",
                                           description: Text(model.hasSearched ? "Try another title." : "Enter an anime title to get started."))
                        .accessibilityIdentifier("catalog.empty")
                } else {
                    List(model.items, id: \.id) { media in
                        NavigationLink(value: media.id) {
                            HStack(alignment: .top) {
                                CatalogCover(address: media.coverImage.best)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(media.title.preferred).font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let format = media.format { Text(format).font(.subheadline) }
                                    if let year = media.seasonYear { Text("\(year.intValue)").font(.caption) }
                                }
                            }.frame(minHeight: 44, alignment: .leading)
                        }
                    }.accessibilityIdentifier("catalog.results")
                }
            }
            .navigationTitle("Catalog")
            .navigationDestination(for: Int32.self) { id in
                CatalogDetailsView(id: id, client: model.client)
            }
        }.onDisappear { model.cancel() }
    }
}

private struct CatalogCover: View {
    let address: String?
    var body: some View {
        AsyncImage(url: address.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                // Missing artwork and failed downloads have the same stable decorative fallback.
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }.frame(width: 64, height: 90).accessibilityHidden(true)
    }
}

struct CatalogDetailsView: View {
    let id: Int32
    @StateObject private var model: CatalogDetailsModel

    init(id: Int32, client: CatalogClient) {
        self.id = id
        _model = StateObject(wrappedValue: CatalogDetailsModel(client: client))
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading details…")
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Details unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button { model.load(id: id) } label: { Text("Retry").frame(minHeight: 44) }
                }
            } else if let media = model.media {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(media.title.preferred).font(.title).accessibilityAddTraits(.isHeader)
                            .fixedSize(horizontal: false, vertical: true)
                        CatalogCover(address: media.coverImage.best)
                        if let format = media.format { Text("Format: \(format)") }
                        if let status = media.status { Text("Status: \(status)") }
                        if let episodes = media.episodes { Text("Episodes: \(episodes.intValue)") }
                        if !media.genres.isEmpty { Text(media.genres.joined(separator: ", ")) }
                        if let description = media.synopsis { Text(description) }
                        Text("Episode playback for live providers is not available in this prototype. Use the original Demo journey to test the connected flow.").font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.accessibilityIdentifier("catalog.details")
            } else {
                ContentUnavailableView("Anime not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Anime details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { model.load(id: id) }
        .onDisappear { model.cancel() }
    }
}
