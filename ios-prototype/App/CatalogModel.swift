import Combine
import Foundation
import SharedCore

/// Only HTTP belongs here. GraphQL requests, decoding and domain mapping live in SharedCore.
final class URLSessionCatalogTransport: NSObject, CatalogCallbackTransport {
    private let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session; super.init() }
    deinit { session.invalidateAndCancel() }

    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        guard let url = URL(string: request.url), url.scheme == "https" else {
            completion.complete(response: nil, error: "Catalog requires an HTTPS endpoint.")
            return HTTPTaskCancellation(task: nil)
        }
        var message = URLRequest(url: url)
        message.httpMethod = "POST"
        message.httpBody = Data(request.body.utf8)
        message.setValue("application/json", forHTTPHeaderField: "Content-Type")
        message.setValue("application/json", forHTTPHeaderField: "Accept")
        message.setValue("Anilili-iOS-Prototype/0.1", forHTTPHeaderField: "User-Agent")
        message.setValue("anilili://ios-playback-poc", forHTTPHeaderField: "Referer")
        message.timeoutInterval = 30
        let task = session.dataTask(with: message) { data, response, error in
            if let error = error as NSError? {
                completion.complete(response: nil, error: "Network error \(error.domain) (\(error.code)).")
                return
            }
            guard let http = response as? HTTPURLResponse,
                  let data, let body = String(data: data, encoding: .utf8) else {
                completion.complete(response: nil, error: "The catalog returned an invalid HTTP response.")
                return
            }
            completion.complete(response: CatalogHttpResponse(status: Int32(http.statusCode), body: body), error: nil)
        }
        task.resume()
        return HTTPTaskCancellation(task: task)
    }
}

private final class HTTPTaskCancellation: NSObject, CatalogCancellation {
    private let task: URLSessionDataTask?
    init(task: URLSessionDataTask?) { self.task = task; super.init() }
    func cancel() { task?.cancel() }
}

private final class PageCompletion: NSObject, CatalogPageCompletion {
    private let receive: (MediaPage?, CatalogFailure?) -> Void
    init(_ receive: @escaping (MediaPage?, CatalogFailure?) -> Void) { self.receive = receive; super.init() }
    func complete(page: MediaPage?, failure: CatalogFailure?) { receive(page, failure) }
}

private final class DetailsCompletion: NSObject, CatalogDetailsCompletion {
    private let receive: (Media?, CatalogFailure?) -> Void
    init(_ receive: @escaping (Media?, CatalogFailure?) -> Void) { self.receive = receive; super.init() }
    func complete(media: Media?, failure: CatalogFailure?) { receive(media, failure) }
}

@MainActor
final class CatalogModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var items: [Media] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasSearched = false
    let client: CatalogClient
    private var request: CatalogCancellation?
    private var generation = UUID()

    init(client: CatalogClient = CatalogClient(transport: URLSessionCatalogTransport(), endpoint: "https://graphql.anilist.co")) {
        self.client = client
    }

    func search(allowEmpty: Bool = false) {
        cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        items = []
        hasSearched = allowEmpty || !term.isEmpty
        guard allowEmpty || !term.isEmpty else { return }
        isLoading = true
        let token = generation
        request = client.search(query: term, page: 1, perPage: 20, hideAdult: true, completion: PageCompletion { [weak self] page, failure in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isLoading = false
                self.errorMessage = failure?.message
                self.items = page?.items ?? []
                self.request = nil
            }
        })
    }

    func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        isLoading = false
    }

    deinit { request?.cancel(); client.close() }
}

@MainActor
final class CatalogDetailsModel: ObservableObject {
    @Published private(set) var media: Media?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let client: CatalogClient
    private var request: CatalogCancellation?
    private var generation = UUID()

    init(client: CatalogClient) { self.client = client }

    func load(id: Int32) {
        cancel()
        media = nil
        errorMessage = nil
        isLoading = true
        let token = generation
        request = client.details(id: id, completion: DetailsCompletion { [weak self] media, failure in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isLoading = false
                self.media = media
                self.errorMessage = failure?.message
                self.request = nil
            }
        })
    }

    func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        isLoading = false
    }

    deinit { request?.cancel() }
}
