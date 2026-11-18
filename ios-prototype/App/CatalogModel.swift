import Combine
import Foundation
import SharedCore

/// Only HTTP belongs here. GraphQL requests, decoding and domain mapping live in SharedCore.
final class URLSessionCatalogTransport: NSObject, CatalogCallbackTransport {
    private let session: URLSession
    private let allowLoopback: Bool
    init(session: URLSession = URLSession(configuration: .ephemeral), allowLoopback: Bool = false) {
        self.session = session
        self.allowLoopback = allowLoopback
        super.init()
    }
    deinit { session.invalidateAndCancel() }

    func post(request: CatalogHttpRequest, completion: CatalogHttpCompletion) -> CatalogCancellation {
        guard let url = URL(string: request.url), Self.allowed(url, allowLoopback: allowLoopback) else {
            completion.complete(response: nil, error: "An HTTPS endpoint is required; only explicit fixture transports allow loopback HTTP.")
            return HTTPTaskCancellation(task: nil)
        }
        guard ["GET", "POST"].contains(request.method),
              MediaSourcePolicy.shared.validHeaders(headers: request.headers) else {
            completion.complete(response: nil, error: "Unsupported HTTP method or invalid request headers.")
            return HTTPTaskCancellation(task: nil)
        }
        var message = URLRequest(url: url)
        message.httpMethod = request.method
        if request.method == "POST" { message.httpBody = Data(request.body.utf8) }
        message.setValue("application/json", forHTTPHeaderField: "Content-Type")
        message.setValue("application/json", forHTTPHeaderField: "Accept")
        message.setValue("Anilili-iOS-Prototype/0.1", forHTTPHeaderField: "User-Agent")
        message.setValue("anilili://ios-playback-poc", forHTTPHeaderField: "Referer")
        for (name, value) in request.headers { message.setValue(value, forHTTPHeaderField: name) }
        // Credentials belong to this request, never a shared or global cookie jar.
        message.httpShouldHandleCookies = false
        message.timeoutInterval = 30
        let task = session.dataTask(with: message) { data, response, error in
            if let error = error as NSError? {
                LocalDiagnostics.shared.record(category: .network,
                    event: error.code == NSURLErrorTimedOut ? .timedOut : .resolutionFailed, code: error.code)
                completion.complete(response: nil, error: "Network error \(error.domain) (\(error.code)).")
                return
            }
            guard let http = response as? HTTPURLResponse,
                  let data, let body = String(data: data, encoding: .utf8) else {
                completion.complete(response: nil, error: "The provider returned an invalid HTTP response.")
                return
            }
            if http.statusCode >= 400 {
                LocalDiagnostics.shared.record(category: .network, event: .resolutionFailed, code: http.statusCode)
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let name = pair.key as? String { result[name] = String(describing: pair.value) }
            }
            completion.complete(response: CatalogHttpResponse(status: Int32(http.statusCode), body: body, headers: headers, finalUrl: http.url?.absoluteString), error: nil)
        }
        let redirectDelegate = ProviderRedirectDelegate(initialURL: url, allowLoopback: allowLoopback)
        task.delegate = redirectDelegate
        task.resume()
        return HTTPTaskCancellation(task: task, redirectDelegate: redirectDelegate)
    }

    fileprivate static func allowed(_ url: URL, allowLoopback: Bool) -> Bool {
        guard url.user == nil, url.password == nil, url.host != nil else { return false }
        return url.scheme == "https" || (allowLoopback && url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host!))
    }
}

/// Resolving metadata may redirect, but HTTPS cannot downgrade and credentials never cross origins.
final class ProviderRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let initialURL: URL
    private let allowLoopback: Bool
    private var count = 0
    init(initialURL: URL, allowLoopback: Bool) { self.initialURL = initialURL; self.allowLoopback = allowLoopback; super.init() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        count += 1
        guard count <= 5, let next = request.url,
              URLSessionCatalogTransport.allowed(next, allowLoopback: allowLoopback),
              !(initialURL.scheme == "https" && next.scheme != "https") else { completionHandler(nil); return }
        var forwarded = request
        let previous = response.url ?? initialURL
        if previous.scheme != next.scheme || previous.host != next.host || previous.port != next.port {
            // Replacing allHTTPHeaderFields on Foundation's proposed redirect request can
            // retain its original headers. Build a new request instead of mutating that copy.
            guard ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else {
                completionHandler(nil); return
            }
            forwarded = URLRequest(url: next, cachePolicy: request.cachePolicy,
                                   timeoutInterval: request.timeoutInterval)
            forwarded.httpMethod = request.httpMethod ?? "GET"
            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                if ["accept", "user-agent"].contains(name.lowercased()) {
                    forwarded.setValue(value, forHTTPHeaderField: name)
                }
            }
        }
        forwarded.httpShouldHandleCookies = false
        completionHandler(forwarded)
    }
}

private final class HTTPTaskCancellation: NSObject, CatalogCancellation {
    private let task: URLSessionDataTask?
    private let redirectDelegate: ProviderRedirectDelegate?
    init(task: URLSessionDataTask?, redirectDelegate: ProviderRedirectDelegate? = nil) {
        self.task = task; self.redirectDelegate = redirectDelegate; super.init()
    }
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
                if let failure { LocalDiagnostics.shared.record(category: .resolution, event: .catalogFailed, code: Int(failure.status)) }
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
                if let failure { LocalDiagnostics.shared.record(category: .resolution, event: .catalogFailed, code: Int(failure.status)) }
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
