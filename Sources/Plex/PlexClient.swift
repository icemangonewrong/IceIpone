import Foundation

enum PlexError: LocalizedError {
    case notSignedIn
    case noServer
    case badResponse(Int)
    case noConnection

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Plex."
        case .noServer: return "No Plex server selected."
        case .badResponse(let code): return "Plex returned an error (\(code))."
        case .noConnection: return "Couldn't reach the Plex server on any address."
        }
    }
}

/// Talks to plex.tv and to your Plex Media Server.
final class PlexClient {
    static let product = "Ice"

    let clientIdentifier: String
    var token: String?
    var server: SavedServer?
    /// Called when we fail over to a different server address, so it can be saved.
    var onServerURLChanged: ((SavedServer) -> Void)?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    init(clientIdentifier: String) {
        self.clientIdentifier = clientIdentifier
    }

    // MARK: - Headers

    func plexHeaders(token: String? = nil) -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Product": Self.product,
            "X-Plex-Version": "1.0",
            "X-Plex-Platform": "iOS",
            "X-Plex-Device": "iPhone",
            "X-Plex-Device-Name": "Ice",
        ]
        if let t = token { h["X-Plex-Token"] = t }
        return h
    }

    private func request(_ url: URL, method: String = "GET", token: String?, timeout: TimeInterval? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let timeout { r.timeoutInterval = timeout }
        for (k, v) in plexHeaders(token: token) { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.badResponse(http.statusCode)
        }
        return data
    }

    // MARK: - plex.tv sign-in (PIN flow)

    func createPin() async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins?strong=true")!
        let data = try await send(request(url, method: "POST", token: nil))
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    func checkPin(id: Int) async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!
        let data = try await send(request(url, token: nil))
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    func authURL(for pin: PlexPin) -> URL {
        // Plex's auth page reads its parameters from the URL fragment.
        let id = clientIdentifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? clientIdentifier
        let code = pin.code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? pin.code
        let s = "https://app.plex.tv/auth#?clientID=\(id)&code=\(code)&context%5Bdevice%5D%5Bproduct%5D=\(Self.product)"
        return URL(string: s) ?? URL(string: "https://app.plex.tv")!
    }

    // MARK: - Servers

    func servers() async throws -> [PlexResource] {
        guard let token else { throw PlexError.notSignedIn }
        let url = URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        let data = try await send(request(url, token: token))
        let all = try JSONDecoder().decode([PlexResource].self, from: data)
        return all.filter { $0.isServer }
    }

    /// Tries each address for a server (local first, relay last) and returns the first that answers.
    func connect(to resource: PlexResource) async throws -> SavedServer {
        let serverToken = resource.accessToken ?? token ?? ""
        let conns = (resource.connections ?? []).sorted { a, b in
            func rank(_ c: PlexConnection) -> Int {
                if c.relay == true { return 2 }
                return c.local == true ? 0 : 1
            }
            return rank(a) < rank(b)
        }
        let uris = conns.map(\.uri)
        guard let working = await firstReachable(uris: uris, token: serverToken) else {
            throw PlexError.noConnection
        }
        return SavedServer(name: resource.name, clientIdentifier: resource.clientIdentifier,
                           accessToken: serverToken, baseURL: working, allURIs: uris)
    }

    private func firstReachable(uris: [String], token: String) async -> String? {
        for uri in uris {
            guard let url = URL(string: uri + "/identity") else { continue }
            if (try? await send(request(url, token: token, timeout: 5))) != nil { return uri }
        }
        return nil
    }

    // MARK: - Server requests (with fail-over between addresses)

    private func serverGET(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let server else { throw PlexError.noServer }
        do {
            return try await send(request(try serverURL(base: server.baseURL, path: path, query: query),
                                          token: server.accessToken))
        } catch let err as URLError {
            // Address stopped working (e.g. truck left the home Wi-Fi). Try the others.
            let others = server.allURIs.filter { $0 != server.baseURL }
            guard let working = await firstReachable(uris: others, token: server.accessToken) else { throw err }
            let updated = SavedServer(name: server.name, clientIdentifier: server.clientIdentifier,
                                      accessToken: server.accessToken, baseURL: working, allURIs: server.allURIs)
            self.server = updated
            onServerURLChanged?(updated)
            return try await send(request(try serverURL(base: working, path: path, query: query),
                                          token: updated.accessToken))
        }
    }

    private func serverURL(base: String, path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(string: base + path) else { throw PlexError.noServer }
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query }
        guard let url = comps.url else { throw PlexError.noServer }
        return url
    }

    private func decodeItems(_ data: Data) throws -> [PlexItem] {
        try JSONDecoder().decode(PlexResponse<MetadataContainer>.self, from: data).MediaContainer.Metadata ?? []
    }

    private func decodeHubs(_ data: Data) throws -> [PlexHub] {
        try JSONDecoder().decode(PlexResponse<HubsContainer>.self, from: data).MediaContainer.Hub ?? []
    }

    // MARK: - Library

    func sections() async throws -> [PlexSection] {
        let data = try await serverGET("/library/sections")
        let dirs = try JSONDecoder().decode(PlexResponse<SectionsContainer>.self, from: data).MediaContainer.Directory ?? []
        return dirs.filter { $0.isVideo }
    }

    /// Continue Watching. Newer servers have a dedicated hub; older ones use On Deck.
    func continueWatching() async throws -> [PlexItem] {
        if let data = try? await serverGET("/hubs/home/continueWatching"),
           let hubs = try? decodeHubs(data) {
            let items = hubs.flatMap { $0.Metadata ?? [] }
            if !items.isEmpty { return items }
        }
        if let data = try? await serverGET("/hubs", query: [URLQueryItem(name: "count", value: "30")]),
           let hubs = try? decodeHubs(data) {
            let match = hubs.first { ($0.hubIdentifier ?? "").contains("continue") }
                ?? hubs.first { ($0.hubIdentifier ?? "").contains("ondeck") }
            if let items = match?.Metadata, !items.isEmpty { return items }
        }
        return try decodeItems(try await serverGET("/library/onDeck"))
    }

    func recentlyAdded(section: String, count: Int = 30) async throws -> [PlexItem] {
        let data = try await serverGET("/library/sections/\(section)/recentlyAdded", query: [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(count)),
        ])
        return try decodeItems(data)
    }

    func items(section: String, sort: String, unwatchedOnly: Bool, start: Int, size: Int) async throws -> (items: [PlexItem], total: Int?) {
        var q = [
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size)),
        ]
        if unwatchedOnly { q.append(URLQueryItem(name: "unwatched", value: "1")) }
        let data = try await serverGET("/library/sections/\(section)/all", query: q)
        let mc = try JSONDecoder().decode(PlexResponse<MetadataContainer>.self, from: data).MediaContainer
        return (mc.Metadata ?? [], mc.totalSize)
    }

    func children(of ratingKey: String) async throws -> [PlexItem] {
        try decodeItems(try await serverGET("/library/metadata/\(ratingKey)/children"))
    }

    /// Fresh copy of one item (to get the latest resume position).
    func metadata(_ ratingKey: String) async throws -> PlexItem? {
        try decodeItems(try await serverGET("/library/metadata/\(ratingKey)")).first
    }

    /// Next unwatched (or in-progress) episode of a show, for a "Play" button on a show.
    func nextEpisode(showKey: String) async throws -> PlexItem? {
        let eps = try decodeItems(try await serverGET("/library/metadata/\(showKey)/allLeaves"))
        return eps.first { ($0.viewOffset ?? 0) > 0 } ?? eps.first { ($0.viewCount ?? 0) == 0 } ?? eps.first
    }

    /// Full details including intro/credits markers and subtitle files.
    func details(_ ratingKey: String) async throws -> PlexItem? {
        try decodeItems(try await serverGET("/library/metadata/\(ratingKey)",
                                            query: [URLQueryItem(name: "includeMarkers", value: "1")])).first
    }

    /// The episode right after / before this one, across seasons.
    func episode(adjacentTo item: PlexItem, offset: Int) async throws -> PlexItem? {
        guard item.type == "episode", let show = item.grandparentRatingKey?.value else { return nil }
        let eps = try decodeItems(try await serverGET("/library/metadata/\(show)/allLeaves"))
        guard let i = eps.firstIndex(where: { $0.ratingKey == item.ratingKey }) else { return nil }
        let j = i + offset
        return eps.indices.contains(j) ? eps[j] : nil
    }

    /// Address of a subtitle file Plex keeps next to a video.
    func streamURL(_ key: String) -> URL? {
        guard let server else { return nil }
        var comps = URLComponents(string: server.baseURL + key)
        comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: server.accessToken)]
        return comps?.url
    }

    func search(_ text: String) async throws -> [PlexItem] {
        let data = try await serverGET("/hubs/search", query: [
            URLQueryItem(name: "query", value: text),
            URLQueryItem(name: "limit", value: "20"),
        ])
        let hubs = try decodeHubs(data)
        return hubs
            .filter { ["movie", "show", "episode"].contains($0.type ?? "") }
            .flatMap { $0.Metadata ?? [] }
    }

    // MARK: - Watch state

    func reportTimeline(item: PlexItem, state: String, timeMs: Int, durationMs: Int) async {
        _ = try? await serverGET("/:/timeline", query: [
            URLQueryItem(name: "ratingKey", value: item.ratingKey.value),
            URLQueryItem(name: "key", value: "/library/metadata/\(item.ratingKey.value)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
        ])
    }

    func markWatched(_ ratingKey: String) async {
        _ = try? await serverGET("/:/scrobble", query: [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: ratingKey),
        ])
    }

    func markUnwatched(_ ratingKey: String) async {
        _ = try? await serverGET("/:/unscrobble", query: [
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "key", value: ratingKey),
        ])
    }

    func stopTranscode(session: String) async {
        _ = try? await serverGET("/video/:/transcode/universal/stop", query: [
            URLQueryItem(name: "session", value: session),
        ])
    }

    // MARK: - URLs for images and video

    func imageURL(_ path: String?, width: Int = 300, height: Int = 450) -> URL? {
        guard let path, let server else { return nil }
        var comps = URLComponents(string: server.baseURL + "/photo/:/transcode")
        comps?.queryItems = [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
        ]
        return comps?.url
    }

    /// Direct-play address of the original file (no server-side conversion at all).
    func directURL(for item: PlexItem) -> URL? {
        guard let server, let partKey = item.firstPart?.key else { return nil }
        var comps = URLComponents(string: server.baseURL + partKey)
        comps?.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: server.accessToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: Self.product),
        ]
        return comps?.url
    }
}
