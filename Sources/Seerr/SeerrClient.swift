import Foundation

/// Seerr: search everything (not just the library) and request it. Ice signs in with the Plex account it
/// already has, so requests show up in Seerr under that user as if made on Seerr's own website.
struct SeerrResult: Identifiable, Hashable {
    let id: Int
    let kind: String          // "movie" or "tv"
    let title: String
    let year: String
    let overview: String
    let poster: URL?
    let status: Int

    var kindText: String { kind == "movie" ? "Movie" : "TV show" }
    var statusText: String? { SeerrClient.statusText[status] }
}

struct SeerrSeason: Identifiable, Hashable {
    let number: Int
    let name: String
    let episodes: Int
    let status: Int
    var id: Int { number }
}

struct SeerrDetails {
    var status: Int
    var overview: String
    var genres: [String]
    var runtime: Int?
    var seasons: [SeerrSeason]
    var imdb: Double?
}

enum SeerrError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

final class SeerrClient {
    static let pending = 2, processing = 3, partial = 4, available = 5
    static let statusText: [Int: String] = [2: "Requested", 3: "Requested", 4: "Partly available", 5: "Available"]
    static let defaultURL = "http://10.66.66.1:5056"

    static var savedURL: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "seerrUrl") ?? defaultURL
            return saved == "http://10.66.66.1:5055" ? defaultURL : saved   // the first default had the wrong port
        }
        set { UserDefaults.standard.set(newValue, forKey: "seerrUrl") }
    }

    let base: String
    let plexToken: String
    private let session: URLSession
    private var signedIn = false

    init?(url: String, plexToken: String?) {
        var b = url.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty, let token = plexToken, !token.isEmpty else { return nil }
        if !b.contains("://") { b = "http://" + b }
        base = b
        self.plexToken = token
        let cfg = URLSessionConfiguration.ephemeral   // own cookie jar for Seerr's sign-in cookie
        cfg.timeoutIntervalForRequest = 20
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpShouldSetCookies = true
        session = URLSession(configuration: cfg)
    }

    private var unreachable: SeerrError { .message("Can't reach Seerr at \(base) (is WireGuard on?)") }

    private func send(_ method: String, _ path: String, body: Any? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: base + "/api/v1" + path) else { throw SeerrError.message("Bad Seerr address.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, resp) = try await session.dataCompat(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw unreachable
        }
    }

    private func login() async throws {
        let (_, code) = try await send("POST", "/auth/plex", body: ["authToken": plexToken])
        if code == 403 { throw SeerrError.message("Seerr didn't let this Plex account in.") }
        if code >= 400 || code == 0 { throw SeerrError.message("Seerr sign-in failed (\(code)).") }
        signedIn = true
    }

    private func call(_ method: String, _ path: String, body: Any? = nil) async throws -> Any {
        if !signedIn { try await login() }
        for attempt in 1...2 {
            let (data, code) = try await send(method, path, body: body)
            if (code == 401 || code == 403) && attempt == 1 {
                try await login()     // session expired: sign in again once
                continue
            }
            if code >= 400 {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                throw SeerrError.message(msg ?? "Seerr said \(code).")
            }
            return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) ?? [:])
        }
        throw SeerrError.message("Seerr sign-in keeps failing.")
    }

    func test() async throws -> String {
        try await login()
        let me = try await call("GET", "/auth/me") as? [String: Any] ?? [:]
        return (me["displayName"] as? String) ?? (me["plexUsername"] as? String) ?? "OK"
    }

    func search(_ query: String) async throws -> [SeerrResult] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let data = try await call("GET", "/search?query=\(q)&page=1") as? [String: Any] ?? [:]
        let results = data["results"] as? [[String: Any]] ?? []
        return results.compactMap { r in
            guard let kind = r["mediaType"] as? String, kind == "movie" || kind == "tv",
                  let id = r["id"] as? Int else { return nil }
            let date = (kind == "movie" ? r["releaseDate"] : r["firstAirDate"]) as? String ?? ""
            let poster = (r["posterPath"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w342" + $0) }
            let status = ((r["mediaInfo"] as? [String: Any])?["status"] as? Int) ?? 1
            return SeerrResult(id: id, kind: kind,
                               title: (kind == "movie" ? r["title"] : r["name"]) as? String ?? "",
                               year: String(date.prefix(4)), overview: r["overview"] as? String ?? "",
                               poster: poster, status: status)
        }
    }

    func details(_ r: SeerrResult) async throws -> SeerrDetails {
        let d = try await call("GET", "/\(r.kind)/\(r.id)") as? [String: Any] ?? [:]
        let mi = d["mediaInfo"] as? [String: Any] ?? [:]
        var info = SeerrDetails(status: mi["status"] as? Int ?? 1, overview: d["overview"] as? String ?? r.overview,
                                genres: (d["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                                runtime: d["runtime"] as? Int, seasons: [], imdb: nil)
        if r.kind == "tv" {
            var have: [Int: Int] = [:]
            for s in mi["seasons"] as? [[String: Any]] ?? [] {
                if let n = s["seasonNumber"] as? Int { have[n] = s["status"] as? Int ?? 1 }
            }
            for rq in mi["requests"] as? [[String: Any]] ?? [] {
                for s in rq["seasons"] as? [[String: Any]] ?? [] {
                    if let n = s["seasonNumber"] as? Int, have[n] == nil { have[n] = SeerrClient.pending }
                }
            }
            for s in d["seasons"] as? [[String: Any]] ?? [] {
                guard let n = s["seasonNumber"] as? Int, n > 0 else { continue }   // skip Specials
                info.seasons.append(SeerrSeason(number: n, name: s["name"] as? String ?? "Season \(n)",
                                                episodes: s["episodeCount"] as? Int ?? 0, status: have[n] ?? 1))
            }
        } else if let ratings = try? await call("GET", "/movie/\(r.id)/ratingscombined") as? [String: Any] {
            if let imdb = ratings["imdb"] as? [String: Any], let score = imdb["criticsScore"] as? Double {
                info.imdb = score
            }
        }
        return info
    }

    func request(_ r: SeerrResult, seasons: [Int]?) async throws {
        var body: [String: Any] = ["mediaType": r.kind, "mediaId": r.id]
        if r.kind == "tv" { body["seasons"] = seasons.map { $0 as Any } ?? "all" }
        _ = try await call("POST", "/request", body: body)
    }
}
