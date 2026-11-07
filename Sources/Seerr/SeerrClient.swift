import Foundation

/// Seerr: browse and search everything (not just the library) and request it. Ice signs in with the Plex account
/// it already has, so requests show up in Seerr under that user as if made on Seerr's own website.
struct SeerrResult: Identifiable, Hashable {
    let id: Int
    let kind: String          // "movie" or "tv"
    let title: String
    let year: String
    let overview: String
    let poster: URL?
    var status: Int
    var backdrop: URL? = nil
    var ratingKey: String? = nil     // Plex ratingKey when it's in the library
    var votes: Int = 0
    var vote: Double? = nil
    var date: String = ""
    var role: String = ""            // character or job (filmographies)
    var department: String = ""
    var episodes: Int? = nil

    var uid: String { "\(kind):\(id)" }
    var kindText: String { kind == "movie" ? "Movie" : "TV show" }
    var statusText: String? { SeerrClient.statusText[status] }
    /// "lib" (in your library), "req" (requested) or nil.
    var mark: String? {
        if status == SeerrClient.available || status == SeerrClient.partial { return "lib" }
        if status == SeerrClient.pending || status == SeerrClient.processing { return "req" }
        return nil
    }
}

struct SeerrSeason: Identifiable, Hashable {
    let number: Int
    let name: String
    let episodes: Int
    let status: Int
    var airDate: String = ""
    var id: Int { number }
}

struct SeerrPerson: Identifiable, Hashable {
    let id: Int?
    let name: String
    let role: String
    let photo: URL?
    var uid: String { "\(id ?? 0):\(name):\(role)" }
}

struct SeerrLink: Hashable {
    let id: Int
    let name: String
    var poster: URL? = nil
}

struct SeerrTitle {
    var result: SeerrResult
    var imdbID: String?
    var cert: String
    var tagline: String
    var runtime: Int?
    var genres: [String]
    var cast: [SeerrPerson]
    var directors: [SeerrPerson]
    var writers: [SeerrPerson]
    var creators: [SeerrPerson]
    var studio: SeerrLink?
    var network: SeerrLink?
    var providers: [SeerrLink]
    var collection: SeerrLink?
    var trailer: URL?
    var seasons: [SeerrSeason]
    var numSeasons: Int?
}

struct CreditGroup: Identifiable {
    let name: String
    let items: [SeerrResult]
    var id: String { name }
}

struct SeerrPersonDetails {
    let id: Int
    let name: String
    let bio: String
    let birthday: String
    let deathday: String
    let place: String
    let dept: String
    let photo: URL?
    let known: [SeerrResult]
    let groups: [CreditGroup]
}

struct SeerrCollection {
    let name: String
    let overview: String
    let backdrop: URL?
    var parts: [SeerrResult]
}

struct SeerrService: Identifiable, Hashable {
    let id: Int
    let name: String
    let logo: URL?
}

struct SeerrRequest: Identifiable {
    let requestID: Int
    let reqStatus: Int        // 1 waiting for approval, 2 approved, 3 declined
    let kind: String
    let tmdbID: Int
    let status: Int
    let ratingKey: String?
    let requestedAt: String
    let seasonsRequested: [Int]
    // Filled in from the title itself:
    var title = ""
    var year = ""
    var date = ""
    var poster: URL?
    var cert = ""
    var seasons: [SeerrSeason] = []
    var id: Int { requestID }

    var asResult: SeerrResult {
        SeerrResult(id: tmdbID, kind: kind, title: title, year: year, overview: "", poster: poster, status: status,
                    ratingKey: ratingKey, date: date)
    }
}

struct SeerrEpisode: Hashable {
    let number: Int
    let name: String
    let airDate: String
}

enum SeerrError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

final class SeerrClient {
    static let unknown = 1, pending = 2, processing = 3, partial = 4, available = 5
    static let statusText: [Int: String] = [2: "Requested", 3: "Requested", 4: "Partly available", 5: "Available"]
    static let defaultURL = "http://10.66.66.1:5056"
    static let region = "US"
    static let img = "https://image.tmdb.org/t/p/w342"
    static let backdropImg = "https://image.tmdb.org/t/p/w1280"
    static let face = "https://image.tmdb.org/t/p/w185"
    static let logoImg = "https://image.tmdb.org/t/p/w154"

    // TMDB ids of TV networks and movie studios (the same ones Seerr's own Discover page shows).
    static let networks: [(String, Int)] = [
        ("Netflix", 213), ("HBO", 49), ("Max", 3186), ("Disney+", 2739), ("Prime Video", 1024), ("Apple TV+", 2552),
        ("Hulu", 453), ("Paramount+", 4330), ("Peacock", 3353), ("AMC", 174), ("FX", 88), ("Showtime", 67),
        ("Starz", 318), ("Paramount Network", 2076), ("NBC", 6), ("CBS", 16), ("ABC", 2), ("FOX", 19),
        ("History", 65), ("Discovery", 64)]
    static let studios: [(String, Int)] = [
        ("A24", 41077), ("Marvel Studios", 420), ("Pixar", 3), ("Walt Disney Pictures", 2), ("Warner Bros.", 174),
        ("Universal", 33), ("Paramount", 4), ("Sony Pictures", 34), ("20th Century", 127928), ("DreamWorks", 521),
        ("Lucasfilm", 1), ("Legendary", 923), ("Blumhouse", 3172), ("Lionsgate", 1632)]
    static let serviceNames: [(String, [String])] = [
        ("Netflix", ["netflix"]), ("Disney+", ["disney plus", "disney+"]), ("Max", ["max", "hbo max"]),
        ("Prime Video", ["amazon prime video"]), ("Apple TV+", ["apple tv plus", "apple tv+", "apple tv"]),
        ("Hulu", ["hulu"]), ("Peacock", ["peacock premium", "peacock"]),
        ("Paramount+", ["paramount plus", "paramount+", "paramount plus premium"])]

    static var savedURL: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "seerrUrl") ?? defaultURL
            return saved == "http://10.66.66.1:5055" ? defaultURL : saved   // the first default had the wrong port
        }
        set { UserDefaults.standard.set(newValue, forKey: "seerrUrl") }
    }

    /// One shared connection (keeps its sign-in) for the saved address and this Plex account.
    private static var cached: SeerrClient?
    static func shared(_ token: String?) -> SeerrClient? {
        guard let token, !token.isEmpty, let b = normalized(savedURL) else { return nil }
        if let old = cached, old.base == b, old.plexToken == token { return old }
        cached = SeerrClient(url: b, plexToken: token)
        return cached
    }

    static func normalized(_ url: String) -> String? {
        var b = url.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        if b.isEmpty { return nil }
        return b.contains("://") ? b : "http://" + b
    }

    let base: String
    let plexToken: String
    private let session: URLSession
    private var signedIn = false
    private var loginTask: Task<Void, Error>?
    /// Seerr's sign-in cookie, sent by hand: Seerr can mark it HTTPS-only, and this runs over plain http
    /// (WireGuard), so the system cookie handling would never send it back.
    private var cookie: String?

    init?(url: String, plexToken: String?) {
        var b = url.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty, let token = plexToken, !token.isEmpty else { return nil }
        if !b.contains("://") { b = "http://" + b }
        base = b
        self.plexToken = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg)
    }

    private var unreachable: SeerrError { .message("Can't reach Seerr at \(base).") }

    /// One request; a connection that's still coming up (WireGuard) gets a few seconds before giving up.
    private func send(_ method: String, _ path: String, body: Any? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: base + "/api/v1" + path) else { throw SeerrError.message("Bad Seerr address.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for wait in [1.5, 3.0, -1] {
            do {
                let (data, resp) = try await session.dataCompat(for: req)
                let http = resp as? HTTPURLResponse
                if let set = http?.value(forHTTPHeaderField: "Set-Cookie"),
                   let r = set.range(of: #"connect\.sid=[^;,\s]+"#, options: .regularExpression) {
                    cookie = String(set[r])
                }
                return (data, http?.statusCode ?? 0)
            } catch {
                if wait < 0 || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        throw unreachable
    }

    private func login() async throws {
        if let t = loginTask { return try await t.value }
        let t = Task { [self] () async throws -> Void in
            cookie = nil
            let (_, code) = try await send("POST", "/auth/plex", body: ["authToken": plexToken])
            if code == 403 { throw SeerrError.message("Seerr didn't let this Plex account in.") }
            if code >= 400 || code == 0 { throw SeerrError.message("Seerr sign-in failed (\(code)).") }
            if cookie == nil { throw SeerrError.message("Seerr signed in but sent no session cookie.") }
            signedIn = true
        }
        loginTask = t
        defer { loginTask = nil }
        try await t.value
    }

    func call(_ method: String, _ path: String, body: Any? = nil) async throws -> Any {
        if !signedIn { try await login() }
        for attempt in 1...2 {
            let (data, code) = try await send(method, path, body: body)
            if (code == 401 || code == 403) && attempt == 1 {
                signedIn = false
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
        signedIn = false
        try await login()
        let me = try await call("GET", "/auth/me") as? [String: Any] ?? [:]
        return (me["displayName"] as? String) ?? (me["plexUsername"] as? String) ?? "OK"
    }

    // MARK: - Parsing

    static func url(_ prefix: String, _ path: Any?) -> URL? {
        (path as? String).flatMap { URL(string: prefix + $0) }
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        return nil
    }

    /// One movie or show from a list (search, discover, credits).
    static func parse(_ r: [String: Any], kind fallback: String? = nil) -> SeerrResult? {
        var kind = (r["mediaType"] as? String) ?? fallback ?? ""
        if kind.isEmpty {
            kind = (r["firstAirDate"] != nil || (r["name"] != nil && r["title"] == nil)) ? "tv" : "movie"
        }
        guard kind == "movie" || kind == "tv", let id = r["id"] as? Int else { return nil }
        let date = (kind == "movie" ? r["releaseDate"] : r["firstAirDate"]) as? String ?? ""
        let mi = r["mediaInfo"] as? [String: Any] ?? [:]
        let title = (kind == "movie" ? (r["title"] ?? r["name"]) : (r["name"] ?? r["title"])) as? String ?? ""
        var x = SeerrResult(id: id, kind: kind, title: title, year: String(date.prefix(4)),
                            overview: r["overview"] as? String ?? "", poster: url(img, r["posterPath"]),
                            status: mi["status"] as? Int ?? unknown)
        x.backdrop = url(backdropImg, r["backdropPath"])
        x.ratingKey = str(mi["ratingKey"])
        x.votes = r["voteCount"] as? Int ?? 0
        x.vote = r["voteAverage"] as? Double
        x.date = date
        x.role = (r["character"] as? String) ?? (r["job"] as? String) ?? ""
        x.department = r["department"] as? String ?? ""
        x.episodes = r["episodeCount"] as? Int
        return x
    }

    static func cert(_ kind: String, _ d: [String: Any]) -> String {
        if kind == "movie" {
            for r in (d["releases"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            where r["iso_3166_1"] as? String == region {
                let dates = (r["release_dates"] as? [[String: Any]] ?? [])
                    .sorted { (($0["type"] as? Int) == 3 ? 0 : 1) < (($1["type"] as? Int) == 3 ? 0 : 1) }
                if let c = dates.compactMap({ $0["certification"] as? String }).first(where: { !$0.isEmpty }) { return c }
            }
            return ""
        }
        for r in (d["contentRatings"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        where r["iso_3166_1"] as? String == region {
            if let c = r["rating"] as? String, !c.isEmpty { return c }
        }
        return ""
    }

    static func imdbID(_ d: [String: Any]) -> String? {
        ((d["externalIds"] as? [String: Any])?["imdbId"] as? String) ?? (d["imdbId"] as? String)
    }

    private func list(_ path: String, page: Int, params: [String: String] = [:]) async throws
        -> (items: [SeerrResult], pages: Int, total: Int?) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~,|")
        var q = "page=\(page)"
        for (k, v) in params.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
            q += "&\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }
        let data = try await call("GET", path + (path.contains("?") ? "&" : "?") + q) as? [String: Any] ?? [:]
        let items = (data["results"] as? [[String: Any]] ?? []).compactMap { SeerrClient.parse($0) }
        return (items, data["totalPages"] as? Int ?? 1, data["totalResults"] as? Int)
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [SeerrResult] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let data = try await call("GET", "/search?query=\(q)&page=1") as? [String: Any] ?? [:]
        return (data["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let k = r["mediaType"] as? String, k == "movie" || k == "tv" else { return nil }
            return SeerrClient.parse(r)
        }
    }

    func searchPeople(_ query: String) async throws -> [SeerrPerson] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let data = try await call("GET", "/search?query=\(q)&page=1") as? [String: Any] ?? [:]
        let dept = ["Acting": "Actor", "Directing": "Director", "Writing": "Writer", "Production": "Producer"]
        return (data["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard r["mediaType"] as? String == "person", let id = r["id"] as? Int else { return nil }
            let d = r["knownForDepartment"] as? String ?? ""
            return SeerrPerson(id: id, name: r["name"] as? String ?? "", role: dept[d] ?? d,
                               photo: SeerrClient.url(SeerrClient.face, r["profilePath"]))
        }
    }

    func findPerson(_ name: String) async throws -> Int? {
        let people = try await searchPeople(name)
        return (people.first { $0.name.lowercased() == name.lowercased() } ?? people.first)?.id
    }

    // MARK: - Discover

    func trending(page: Int = 1) async throws -> (items: [SeerrResult], pages: Int, total: Int?) {
        try await list("/discover/trending", page: page)
    }

    func discover(_ kind: String, page: Int = 1, params: [String: String] = [:]) async throws
        -> (items: [SeerrResult], pages: Int, total: Int?) {
        try await list(kind == "movie" ? "/discover/movies" : "/discover/tv", page: page, params: params)
    }

    func upcoming(_ kind: String, page: Int = 1) async throws -> (items: [SeerrResult], pages: Int, total: Int?) {
        try await list(kind == "movie" ? "/discover/movies/upcoming" : "/discover/tv/upcoming", page: page)
    }

    func services() async throws -> [SeerrService] {
        let rows = (try await call("GET", "/watchproviders/movies?watchRegion=\(SeerrClient.region)") as? [[String: Any]] ?? [])
            .sorted { ($0["displayPriority"] as? Int ?? 999) < ($1["displayPriority"] as? Int ?? 999) }
        return SeerrClient.serviceNames.compactMap { label, names in
            guard let hit = rows.first(where: { names.contains(($0["name"] as? String ?? "").lowercased()) }),
                  let id = hit["id"] as? Int else { return nil }
            return SeerrService(id: id, name: label, logo: SeerrClient.url(SeerrClient.logoImg, hit["logoPath"]))
        }
    }

    func genres(_ kind: String) async throws -> [SeerrLink] {
        (try await call("GET", "/genres/\(kind == "movie" ? "movie" : "tv")") as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? Int, let n = $0["name"] as? String else { return nil }
            return SeerrLink(id: id, name: n)
        }
    }

    // MARK: - One title

    /// IMDb id and age rating for a poster (lists don't include them).
    func extra(_ kind: String, _ id: Int) async throws -> (imdb: String?, cert: String) {
        let d = try await call("GET", "/\(kind)/\(id)") as? [String: Any] ?? [:]
        return (SeerrClient.imdbID(d), SeerrClient.cert(kind, d))
    }

    func title(_ kind: String, _ id: Int) async throws -> SeerrTitle {
        var d = try await call("GET", "/\(kind)/\(id)") as? [String: Any] ?? [:]
        d["mediaType"] = kind
        let r = SeerrClient.parse(d) ?? SeerrResult(id: id, kind: kind, title: "", year: "", overview: "", poster: nil,
                                                     status: SeerrClient.unknown)
        let mi = d["mediaInfo"] as? [String: Any] ?? [:]
        let credits = d["credits"] as? [String: Any] ?? [:]
        let crew = credits["crew"] as? [[String: Any]] ?? []
        func people(_ rows: [[String: Any]], _ n: Int = 99) -> [SeerrPerson] {
            var seen = Set<Int>(), out: [SeerrPerson] = []
            for p in rows {
                let pid = p["id"] as? Int ?? 0
                if seen.contains(pid) { continue }
                seen.insert(pid)
                out.append(SeerrPerson(id: pid, name: p["name"] as? String ?? "",
                                       role: (p["character"] as? String) ?? (p["job"] as? String) ?? "",
                                       photo: SeerrClient.url(SeerrClient.face, p["profilePath"])))
                if out.count >= n { break }
            }
            return out
        }
        let trailer = (d["relatedVideos"] as? [[String: Any]] ?? [])
            .first { $0["type"] as? String == "Trailer" }.flatMap { v -> URL? in (v["url"] as? String).flatMap { URL(string: $0) } }
        var providers: [SeerrLink] = []
        for wp in d["watchProviders"] as? [[String: Any]] ?? [] where wp["iso_3166_1"] as? String == SeerrClient.region {
            providers = (wp["flatrate"] as? [[String: Any]] ?? []).compactMap {
                guard let pid = $0["id"] as? Int else { return nil }
                return SeerrLink(id: pid, name: $0["name"] as? String ?? "")
            }
        }
        func link(_ v: Any?) -> SeerrLink? {
            guard let o = v as? [String: Any], let lid = o["id"] as? Int else { return nil }
            return SeerrLink(id: lid, name: o["name"] as? String ?? "", poster: SeerrClient.url(SeerrClient.img, o["posterPath"]))
        }
        var seasons: [SeerrSeason] = []
        if kind == "tv" {
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
                seasons.append(SeerrSeason(number: n, name: s["name"] as? String ?? "Season \(n)",
                                           episodes: s["episodeCount"] as? Int ?? 0, status: have[n] ?? 1,
                                           airDate: s["airDate"] as? String ?? ""))
            }
        }
        let runtime = (d["runtime"] as? Int) ?? (d["episodeRunTime"] as? [Int])?.first
        return SeerrTitle(
            result: r, imdbID: SeerrClient.imdbID(d), cert: SeerrClient.cert(kind, d),
            tagline: d["tagline"] as? String ?? "", runtime: runtime,
            genres: (d["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
            cast: people(credits["cast"] as? [[String: Any]] ?? [], 20),
            directors: people(crew.filter { $0["job"] as? String == "Director" }),
            writers: people(crew.filter { $0["department"] as? String == "Writing" }, 4),
            creators: people(d["createdBy"] as? [[String: Any]] ?? []),
            studio: link((d["productionCompanies"] as? [Any])?.first),
            network: link((d["networks"] as? [Any])?.first),
            providers: providers, collection: link(d["collection"]), trailer: trailer, seasons: seasons,
            numSeasons: d["numberOfSeasons"] as? Int)
    }

    /// Rotten Tomatoes (and IMDb for movies) as Seerr reports them.
    func scores(_ kind: String, _ id: Int) async -> (imdb: Double?, rt: Int?) {
        if kind == "movie" {
            let d = (try? await call("GET", "/movie/\(id)/ratingscombined")) as? [String: Any] ?? [:]
            let imdb = (d["imdb"] as? [String: Any])?["criticsScore"] as? Double
            return (imdb, (d["rt"] as? [String: Any])?["criticsScore"] as? Int)
        }
        let d = (try? await call("GET", "/tv/\(id)/ratings")) as? [String: Any] ?? [:]
        return (nil, d["criticsScore"] as? Int)
    }

    func recommendations(_ kind: String, _ id: Int) async -> [SeerrResult] {
        if let r = try? await list("/\(kind)/\(id)/recommendations", page: 1), !r.items.isEmpty { return r.items }
        return (try? await list("/\(kind)/\(id)/similar", page: 1))?.items ?? []
    }

    func collection(_ id: Int) async throws -> SeerrCollection {
        let d = try await call("GET", "/collection/\(id)") as? [String: Any] ?? [:]
        let parts = (d["parts"] as? [[String: Any]] ?? []).compactMap { SeerrClient.parse($0, kind: "movie") }
            .sorted { ($0.date.isEmpty ? "9999" : $0.date) < ($1.date.isEmpty ? "9999" : $1.date) }
        return SeerrCollection(name: d["name"] as? String ?? "Collection", overview: d["overview"] as? String ?? "",
                               backdrop: SeerrClient.url(SeerrClient.backdropImg, d["backdropPath"]), parts: parts)
    }

    // MARK: - People

    func person(_ id: Int) async throws -> SeerrPersonDetails {
        let d = try await call("GET", "/person/\(id)") as? [String: Any] ?? [:]
        let c = try await call("GET", "/person/\(id)/combined_credits") as? [String: Any] ?? [:]
        let cast = (c["cast"] as? [[String: Any]] ?? []).compactMap { SeerrClient.parse($0) }
        let crew = (c["crew"] as? [[String: Any]] ?? []).compactMap { SeerrClient.parse($0) }
        let dept = d["knownForDepartment"] as? String ?? "Acting"
        let pool = dept == "Acting" ? cast : crew
        var seen = Set<String>(), known: [SeerrResult] = []
        for x in pool.sorted(by: { $0.votes > $1.votes }) {
            let guest = dept == "Acting" && x.kind == "tv" && (x.episodes ?? 99) < 3
            if seen.contains(x.uid) || guest { continue }
            seen.insert(x.uid)
            known.append(x)
            if known.count >= 30 { break }
        }
        var groups: [String: [SeerrResult]] = [:]
        if !cast.isEmpty { groups["Acting"] = cast }
        let depName = ["Directing": "Directing", "Writing": "Writing", "Production": "Producing"]
        for x in crew { groups[depName[x.department] ?? "Crew", default: []].append(x) }
        var merged: [String: [SeerrResult]] = [:]
        for (k, lst) in groups {
            var byID: [String: SeerrResult] = [:], order: [String] = []
            for x in lst {   // one row per title (several jobs on one film become one line)
                if var m = byID[x.uid] {
                    if !x.role.isEmpty && !m.role.contains(x.role) { m.role = m.role.isEmpty ? x.role : m.role + ", " + x.role }
                    byID[x.uid] = m
                } else {
                    byID[x.uid] = x
                    order.append(x.uid)
                }
            }
            merged[k] = order.compactMap { byID[$0] }.sorted { ($0.date.isEmpty ? "0000" : $0.date) > ($1.date.isEmpty ? "0000" : $1.date) }
        }
        let order = dept == "Acting" ? ["Acting", "Directing", "Writing", "Producing", "Crew"]
                                     : ["Directing", "Writing", "Producing", "Acting", "Crew"]
        return SeerrPersonDetails(
            id: id, name: d["name"] as? String ?? "", bio: d["biography"] as? String ?? "",
            birthday: d["birthday"] as? String ?? "", deathday: d["deathday"] as? String ?? "",
            place: d["placeOfBirth"] as? String ?? "", dept: dept,
            photo: SeerrClient.url("https://image.tmdb.org/t/p/h632", d["profilePath"]), known: known,
            groups: order.compactMap { k in merged[k].flatMap { $0.isEmpty ? nil : CreditGroup(name: k, items: $0) } })
    }

    // MARK: - Requests

    func request(_ r: SeerrResult, seasons: [Int]?) async throws {
        var body: [String: Any] = ["mediaType": r.kind, "mediaId": r.id]
        if r.kind == "tv" { body["seasons"] = seasons.map { $0 as Any } ?? "all" }
        _ = try await call("POST", "/request", body: body)
    }

    func myRequests(take: Int = 100) async throws -> [SeerrRequest] {
        let data = try await call("GET", "/request?take=\(take)&skip=0&filter=all&sort=added&sortDirection=desc")
            as? [String: Any] ?? [:]
        return (data["results"] as? [[String: Any]] ?? []).compactMap { rq in
            let media = rq["media"] as? [String: Any] ?? [:]
            guard let kind = (media["mediaType"] as? String) ?? (rq["type"] as? String), kind == "movie" || kind == "tv",
                  let tid = media["tmdbId"] as? Int else { return nil }
            return SeerrRequest(
                requestID: rq["id"] as? Int ?? 0, reqStatus: rq["status"] as? Int ?? 0, kind: kind, tmdbID: tid,
                status: media["status"] as? Int ?? 1, ratingKey: SeerrClient.str(media["ratingKey"]),
                requestedAt: String((rq["createdAt"] as? String ?? "").prefix(10)),
                seasonsRequested: (rq["seasons"] as? [[String: Any]] ?? []).compactMap { $0["seasonNumber"] as? Int }.sorted())
        }
    }

    func fill(_ r: SeerrRequest) async -> SeerrRequest {
        guard var d = (try? await call("GET", "/\(r.kind)/\(r.tmdbID)")) as? [String: Any] else {
            var out = r
            out.title = r.kind == "movie" ? "Movie \(r.tmdbID)" : "Show \(r.tmdbID)"
            return out
        }
        d["mediaType"] = r.kind
        var out = r
        let x = SeerrClient.parse(d)
        out.title = x?.title ?? ""
        out.year = x?.year ?? ""
        out.date = x?.date ?? ""
        out.poster = x?.poster
        out.cert = SeerrClient.cert(r.kind, d)
        out.seasons = (d["seasons"] as? [[String: Any]] ?? []).compactMap { s in
            guard let n = s["seasonNumber"] as? Int, n > 0 else { return nil }
            return SeerrSeason(number: n, name: s["name"] as? String ?? "Season \(n)", episodes: s["episodeCount"] as? Int ?? 0,
                               status: 1, airDate: s["airDate"] as? String ?? "")
        }
        if let imdb = SeerrClient.imdbID(d) {
            await MainActor.run { SeerrExtras.shared.put(out.asResult, imdb: imdb, cert: out.cert) }
        }
        return out
    }

    func seasonEpisodes(_ tmdbID: Int, _ season: Int) async throws -> [SeerrEpisode] {
        let d = try await call("GET", "/tv/\(tmdbID)/season/\(season)") as? [String: Any] ?? [:]
        return (d["episodes"] as? [[String: Any]] ?? []).compactMap { e in
            guard let n = e["episodeNumber"] as? Int else { return nil }
            return SeerrEpisode(number: n, name: e["name"] as? String ?? "", airDate: e["airDate"] as? String ?? "")
        }
    }
}

/// IMDb id + age rating for list entries (lists don't include them): fetched in the background a few at a time
/// and kept on the phone, so each title is only looked up once.
final class SeerrExtras: ObservableObject {   // used on the main thread only
    static let shared = SeerrExtras()

    struct Extra: Codable {
        var imdb: String?
        var cert: String
        var t: Double
    }

    @Published private(set) var data: [String: Extra] = [:]
    private var pending = Set<String>()
    private var queue: [(SeerrClient, SeerrResult)] = []
    private var running = 0
    private var saveScheduled = false
    private let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("seerr_extras.json")

    init() {
        if let d = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Extra].self, from: d) {
            data = saved
        }
    }

    func get(_ r: SeerrResult) -> Extra? { data[r.uid] }

    func put(_ r: SeerrResult, imdb: String?, cert: String) {
        data[r.uid] = Extra(imdb: imdb, cert: cert, t: Date().timeIntervalSince1970)
        scheduleSave()
    }

    func want(_ r: SeerrResult, _ client: SeerrClient?) {
        guard let client else { return }
        if let e = data[r.uid], !e.cert.isEmpty || Date().timeIntervalSince1970 - e.t < 3 * 86400 { return }
        guard !pending.contains(r.uid) else { return }
        pending.insert(r.uid)
        queue.append((client, r))
        pump()
    }

    private func pump() {
        while running < 4, !queue.isEmpty {
            let (client, r) = queue.removeFirst()
            running += 1
            Task { @MainActor in
                if let x = try? await client.extra(r.kind, r.id) { self.put(r, imdb: x.imdb, cert: x.cert) }
                self.pending.remove(r.uid)
                self.running -= 1
                self.pump()
            }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(self.data) { try? d.write(to: self.file, options: .atomic) }
        }
    }
}
