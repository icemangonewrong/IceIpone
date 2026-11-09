import SwiftUI
import UIKit

// Discover: browse everything (not just your library) through Seerr, open any title, actor or director,
// and request with one tap. IMDb scores come from IMDb's own ratings file (IMDbRatings).

let imdbYellow = Color(red: 0.96, green: 0.77, blue: 0.09)
let libGreen = Color(red: 0.13, green: 0.64, blue: 0.28)
let reqAmber = Color(red: 0.85, green: 0.54, blue: 0.0)

@MainActor func seerr(_ app: AppState) -> SeerrClient? { SeerrClient.shared(app.token) }

struct IMDbBadge: View {
    let score: Double
    var size: CGFloat = 11

    var body: some View {
        Text(String(format: "IMDb %.1f", score))
            .font(.system(size: size, weight: .heavy))
            .foregroundColor(.black)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(imdbYellow))
    }
}

struct OutlineBadge: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.5), lineWidth: 1))
    }
}

struct StatusDot: View {
    let mark: String?

    var body: some View {
        if mark == "lib" {
            Image(systemName: "checkmark.circle.fill").palette(.white, libGreen).font(.system(size: 20))
        } else if mark == "req" {
            Image(systemName: "clock.fill").palette(.white, reqAmber).font(.system(size: 18))
                .padding(2).background(Circle().fill(reqAmber))
        }
    }
}

/// In your library: its normal page (to play). Otherwise its title page.
@ViewBuilder
func seerrDestination(_ r: SeerrResult) -> some View {
    if r.status == SeerrClient.available, let rk = r.ratingKey {
        LoadItemView(key: rk)
    } else if r.status == SeerrClient.available {
        LibraryLookupView(result: r)
    } else {
        TitleView(result: r)
    }
}

/// The Plex item for a Seerr title that's in the library. Seerr usually says which one; when it doesn't, look it
/// up in Plex by its TMDB id (or title and year).
@MainActor func findInLibrary(_ app: AppState, _ r: SeerrResult) async -> PlexItem? {
    if let rk = r.ratingKey, let it = try? await app.client.metadata(rk) { return it }
    let want = r.kind == "movie" ? "movie" : "show"
    let hits = ((try? await app.client.search(r.title)) ?? []).filter { $0.type == want }
    return hits.first { $0.tmdbID == r.id }
        ?? hits.first { ($0.title ?? "").lowercased() == r.title.lowercased() && ($0.year.map { String($0) } ?? "") == r.year }
}

/// Play a movie, or a show's next episode.
@MainActor func playFromLibrary(_ app: AppState, _ playback: PlaybackManager, _ item: PlexItem) async {
    if item.type == "show" {
        if let ep = try? await app.client.nextEpisode(showKey: item.ratingKey.value) { await playback.play(ep) }
    } else {
        await playback.play(item)
    }
}

/// Finds an in-library title in Plex, then shows its library page (or the title page if it isn't found).
struct LibraryLookupView: View {
    @EnvironmentObject var app: AppState
    let result: SeerrResult
    @State private var key: String?
    @State private var done = false

    var body: some View {
        Group {
            if let key { LoadItemView(key: key) }
            else if done { TitleView(result: result) }
            else { OrangeSpinner() }
        }
        .taskCompat {
            guard !done else { return }
            key = await findInLibrary(app, result)?.ratingKey.value
            done = true
        }
    }
}

// MARK: - Poster

/// Poster from Seerr: IMDb badge, in-library / requested mark, title, year · rating. Long press to request.
struct SeerrPoster: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playback: PlaybackManager
    @ObservedObject private var extras = SeerrExtras.shared
    @ObservedObject private var ratings = IMDbRatings.shared
    let result: SeerrResult
    var width: CGFloat = 110
    @State private var requested = false
    @State private var working = false

    private var mark: String? { requested ? "req" : result.mark }

    var body: some View {
        let e = extras.get(result)
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                NavigationLink(destination: seerrDestination(result)) {
                    RemoteImage(url: result.poster) {
                        ZStack { Rectangle().fill(Color.gray.opacity(0.25)); Image(systemName: "film").foregroundColor(.secondary) }
                    }
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlayCompat(alignment: .topLeading) {
                        if let s = ratings.rating(e?.imdb) { IMDbBadge(score: s, size: width < 120 ? 10 : 11).padding(5) }
                    }
                    .overlayCompat(alignment: .topTrailing) { StatusDot(mark: mark).padding(4) }
                }
                .plainButton()
            }
            NavigationLink(destination: seerrDestination(result)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.caption.bold()).lineLimit(1).foregroundColor(.white)
                    Text(subtitle(e)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .plainButton()
        }
        .frame(width: width)
        .contextMenu {
            if mark == nil { Button { request() } label: { Label("Request", systemImage: "plus") } }
            if result.mark == "lib" {
                Button {
                    Task { @MainActor in if let it = await findInLibrary(app, result) { await playFromLibrary(app, playback, it) } }
                } label: { Label("Play", systemImage: "play.fill") }
            }
        }
        .onAppear { extras.want(result, seerr(app)) }
    }

    private func subtitle(_ e: SeerrExtras.Extra?) -> String {
        if !result.role.isEmpty { return result.role }
        return [result.year, (e?.cert).flatMap { $0.isEmpty ? nil : $0 } ?? result.kindText]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func request() {
        guard let sr = seerr(app) else { return }
        working = true
        Task { @MainActor in
            do { try await sr.request(result, seasons: nil); requested = true } catch {}
            working = false
        }
    }
}

/// A titled horizontal row of Seerr posters (the title opens the full list when given).
struct SeerrRowView<Dest: View>: View {
    let title: String
    let items: [SeerrResult]
    var width: CGFloat = 110
    var seeAll: Dest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let seeAll {
                NavigationLink(destination: seeAll) {
                    HStack(spacing: 6) {
                        Text(title).font(.title3.bold())
                        Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundColor(.secondary)
                    }
                    .foregroundColor(.white)
                }
                .plainButton()
                .padding(.horizontal)
            } else {
                Text(title).font(.title3.bold()).padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.uid) { r in SeerrPoster(result: r, width: width) }
                }
                .padding(.horizontal)
            }
        }
    }
}

extension SeerrRowView where Dest == EmptyView {
    init(title: String, items: [SeerrResult], width: CGFloat = 110) {
        self.title = title
        self.items = items
        self.width = width
        self.seeAll = nil
    }
}

struct Chip: View {
    let text: String
    var on: Bool = false

    var body: some View {
        Text(text).font(.subheadline.weight(.semibold))
            .foregroundColor(on ? .black : .white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.ice : Color.white.opacity(0.1)))
    }
}

struct Tile: View {
    let text: String
    var logo: URL? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let logo {
                RemoteImage(url: logo) { Color.white.opacity(0.08) }
                    .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Text(text).font(.subheadline.bold()).foregroundColor(.white).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }
}

// MARK: - Discover tab

struct DiscoverView: View {
    @EnvironmentObject var app: AppState
    @State private var kind = "all"
    @State private var rows: [String: [SeerrResult]] = [:]
    @State private var failed: [String: String] = [:]
    @State private var services: [SeerrService] = []
    @State private var genres: [(name: String, ids: [String: Int])] = []
    @State private var loaded = false

    private static let rowDefs: [(key: String, title: String, kind: String)] = [
        ("trending", "Trending this week", "all"), ("pop_movie", "Popular movies", "movie"),
        ("pop_tv", "Popular shows", "tv"), ("up_movie", "Coming soon · Movies", "movie"),
        ("up_tv", "Coming soon · Shows", "tv")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                chips
                if seerr(app) == nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Discover and requests use Seerr. Set it up in Settings → Requests (Seerr).")
                            .foregroundColor(.secondary)
                        NavigationLink(destination: SettingsView()) {
                            Label("Open Settings", systemImage: "gear").padding(.vertical, 4)
                        }
                        .prominentButton()
                    }
                    .padding(.horizontal)
                } else {
                    if failed.count == Self.rowDefs.count {
                        VStack(spacing: 10) {
                            Text(failed.values.first ?? "").foregroundColor(.secondary).multilineTextAlignment(.center)
                            Button("Try again") { loaded = false; Task { await load() } }.borderedButton()
                        }
                        .frame(maxWidth: .infinity).padding()
                    }
                    ForEach(Self.rowDefs.filter { kind == "all" || $0.kind == "all" || $0.kind == kind }, id: \.key) { def in
                        row(def)
                    }
                    servicesSection
                    networksSection
                    genresSection
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Discover")
        .taskCompat { await load() }
        .refreshableCompat { loaded = false; await load() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([["all", "All"], ["movie", "Movies"], ["tv", "Shows"]], id: \.self) { kt in
                    Button { kind = kt[0] } label: { Chip(text: kt[1], on: kind == kt[0]) }.plainButton()
                }
                NavigationLink(destination: RequestsView()) { Chip(text: "Requests") }.plainButton()
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func row(_ def: (key: String, title: String, kind: String)) -> some View {
        if let items = rows[def.key] {
            let shown = items.filter { kind == "all" || $0.kind == kind }
            if !shown.isEmpty {
                SeerrRowView(title: def.title, items: shown, seeAll: seeAll(def))
            }
        } else if failed[def.key] == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(def.title).font(.title3.bold()).padding(.horizontal)
                HStack { OrangeSpinner(size: 24); Spacer() }.padding(.horizontal).frame(height: 120)
            }
        }
    }

    private func seeAll(_ def: (key: String, title: String, kind: String)) -> SeerrGridView {
        switch def.key {
        case "trending": return SeerrGridView(title: def.title, kinds: ["all"], source: .init(special: "trending"), sorts: false)
        case "up_movie": return SeerrGridView(title: def.title, kinds: ["movie"], source: .init(special: "upcoming"), sorts: false)
        case "up_tv": return SeerrGridView(title: def.title, kinds: ["tv"], source: .init(special: "upcoming"), sorts: false)
        default: return SeerrGridView(title: def.title, kinds: [def.kind], source: .init())
        }
    }

    private var kinds: [String] { kind == "all" ? ["movie", "tv"] : [kind] }

    @ViewBuilder
    private var servicesSection: some View {
        if !services.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Streaming services").font(.title3.bold())
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(services) { s in
                        NavigationLink(destination: SeerrGridView(
                            title: s.name, kinds: kinds,
                            source: .init(params: ["watchProviders": String(s.id), "watchRegion": SeerrClient.region]))) {
                            Tile(text: s.name, logo: s.logo)
                        }
                        .plainButton()
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var networksSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if kind != "movie" { chipGrid("Networks", SeerrClient.networks, kind: "tv", param: "network") }
            if kind != "tv" { chipGrid("Studios", SeerrClient.studios, kind: "movie", param: "studio") }
        }
        .padding(.horizontal)
    }

    private func chipGrid(_ title: String, _ list: [(String, Int)], kind: String, param: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(list.map { SeerrLink(id: $0.1, name: $0.0) }, id: \.id) { n in
                    NavigationLink(destination: SeerrGridView(title: n.name, kinds: [kind],
                                                              source: .init(params: [param: String(n.id)]))) {
                        Text(n.name).font(.caption.bold()).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .plainButton()
                }
            }
        }
    }

    @ViewBuilder
    private var genresSection: some View {
        let shown = genres.filter { g in kinds.contains { g.ids[$0] != nil } }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Genres").font(.title3.bold())
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(shown, id: \.name) { g in
                        NavigationLink(destination: SeerrGridView(title: g.name, kinds: kinds.filter { g.ids[$0] != nil },
                                                                  source: .init(genre: g.ids))) {
                            Tile(text: g.name)
                        }
                        .plainButton()
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func load() async {
        guard !loaded, let sr = seerr(app) else { return }
        loaded = true
        failed = [:]
        await withTaskGroup(of: Void.self) { group in
            for def in Self.rowDefs {
                group.addTask {
                    do {
                        let items: [SeerrResult]
                        switch def.key {
                        case "trending": items = try await sr.trending().items
                        case "pop_movie": items = try await sr.discover("movie").items
                        case "pop_tv": items = try await sr.discover("tv").items
                        case "up_movie": items = try await sr.upcoming("movie").items
                        default: items = try await sr.upcoming("tv").items
                        }
                        await MainActor.run { rows[def.key] = items }
                    } catch {
                        await MainActor.run { failed[def.key] = error.localizedDescription }
                    }
                }
            }
            group.addTask {
                let s = (try? await sr.services()) ?? []
                await MainActor.run { services = s }
            }
            group.addTask {
                let m = (try? await sr.genres("movie")) ?? []
                let t = (try? await sr.genres("tv")) ?? []
                var by: [String: [String: Int]] = [:]
                for g in m { by[g.name, default: [:]]["movie"] = g.id }
                for g in t { by[g.name, default: [:]]["tv"] = g.id }
                let list = by.keys.sorted().map { (name: $0, ids: by[$0] ?? [:]) }
                await MainActor.run { genres = list }
            }
        }
    }
}

// MARK: - Full list (see all / service / network / studio / genre)

struct GridSource {
    var special: String? = nil            // "trending" or "upcoming"
    var params: [String: String] = [:]
    var genre: [String: Int] = [:]
}

struct SeerrGridView: View {
    @EnvironmentObject var app: AppState
    let title: String
    let kinds: [String]
    let source: GridSource
    var sorts = true

    @State private var kind = ""
    @State private var sort = "popularity.desc"
    @State private var items: [SeerrResult] = []
    @State private var page = 0
    @State private var pages: Int?
    @State private var total: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var gen = 0

    private static let sortChoices = [["Popular", "popularity.desc"], ["Newest", "date.desc"], ["Top rated", "vote_average.desc"]]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let total {
                    Text("\(total.grouped()) \(word)\(total == 1 ? "" : "s")").font(.subheadline).foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                if kinds.count > 1 || sorts {
                    HStack(spacing: 8) {
                        if kinds.count > 1 {
                            ForEach(kinds, id: \.self) { k in
                                Button { kind = k } label: { Chip(text: k == "movie" ? "Movies" : "Shows", on: current == k) }
                                    .plainButton()
                            }
                        }
                        Spacer()
                        if sorts {
                            Menu {
                                ForEach(Self.sortChoices, id: \.self) { c in
                                    Button { sort = c[1] } label: { Text(c[0]) }
                                }
                            } label: {
                                Chip(text: (Self.sortChoices.first { $0[1] == sort }?[0] ?? "Popular") + "  ▾")
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                if let error { Text(error).foregroundColor(.secondary).padding(.horizontal) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
                    ForEach(items, id: \.uid) { r in
                        SeerrPoster(result: r, width: 104)
                            .onAppear { if r.uid == items.last?.uid { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal)
                if loading { HStack { Spacer(); OrangeSpinner(); Spacer() }.padding() }
            }
            .padding(.vertical)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat(id: "\(current)|\(sort)") { await reload() }
    }

    private var current: String { kind.isEmpty ? kinds[0] : kind }
    private var word: String {
        if source.special == "trending" { return "title" }
        return current == "movie" ? "movie" : current == "tv" ? "show" : "title"
    }

    private func reload() async {
        gen += 1
        items = []
        page = 0
        pages = nil
        total = nil
        error = nil
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, let sr = seerr(app) else { return }
        if let pages, page >= min(pages, 30) { return }
        loading = true
        let myGen = gen, next = page + 1, k = current
        do {
            let res = try await fetch(sr, k, next)
            guard myGen == gen else { return }
            let seen = Set(items.map(\.uid))
            items += res.items.filter { !seen.contains($0.uid) }
            page = next
            pages = res.pages
            if next == 1 { total = res.total }
            if items.isEmpty { error = "Nothing here." }
        } catch {
            if myGen == gen { self.error = error.localizedDescription }
        }
        if myGen == gen { loading = false }
    }

    private func fetch(_ sr: SeerrClient, _ k: String, _ p: Int) async throws -> (items: [SeerrResult], pages: Int, total: Int?) {
        if source.special == "trending" { return try await sr.trending(page: p) }
        if source.special == "upcoming" { return try await sr.upcoming(k, page: p) }
        var params = source.params
        if let g = source.genre[k] { params["genre"] = String(g) }
        var s = sort
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        if s == "date.desc" {
            s = k == "movie" ? "primary_release_date.desc" : "first_air_date.desc"
            params[k == "movie" ? "primaryReleaseDateLte" : "firstAirDateLte"] = today
        } else if s == "vote_average.desc" {
            params["voteCountGte"] = "300"
        }
        params["sortBy"] = s
        return try await sr.discover(k, page: p, params: params)
    }
}

extension Int {
    func grouped() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}

// MARK: - Cast

struct CastCard: View {
    let person: SeerrPerson
    var width: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(url: person.photo) {
                ZStack { Rectangle().fill(Color.white.opacity(0.08)); Image(systemName: "person.fill").foregroundColor(.secondary) }
            }
            .frame(width: width, height: width * 1.25)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.caption.bold()).foregroundColor(.white).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !person.role.isEmpty {
                    Text(person.role).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: width, height: 58, alignment: .topLeading)
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct CastRowView: View {
    let people: [SeerrPerson]
    var title = "Cast"

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(people, id: \.uid) { p in
                            NavigationLink(destination: PersonView(personID: p.id, name: p.name)) { CastCard(person: p) }
                                .plainButton()
                        }
                    }
                }
            }
        }
    }
}

/// Cast from a Plex item (Plex gives names and photos; Seerr finds the person by name).
func plexCast(_ item: PlexItem) -> [SeerrPerson] {
    (item.Role ?? []).prefix(20).map { r in
        SeerrPerson(id: nil, name: r.tag, role: r.role ?? "", photo: r.thumb.flatMap { URL(string: $0) })
    }
}

/// Directors / writers / studio etc. as tappable names.
struct LinkLine<Dest: View>: View {
    let label: String
    let names: [String]
    let destination: (Int) -> Dest

    var body: some View {
        if !names.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).foregroundColor(.secondary).frame(width: 96, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                        NavigationLink(destination: destination(i)) {
                            Text(n).fontWeight(.semibold).foregroundColor(Color.ice)
                        }
                        .plainButton()
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Title page

struct TitleView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playback: PlaybackManager
    @ObservedObject private var ratings = IMDbRatings.shared
    let result: SeerrResult
    @State private var libItem: PlexItem?

    @State private var info: SeerrTitle?
    @State private var scores: (imdb: Double?, rt: Int?) = (nil, nil)
    @State private var recs: [SeerrResult] = []
    @State private var error: String?
    @State private var picked: Set<Int> = []
    @State private var state = ""          // "", "working", "done"
    @State private var requestError: String?

    private func locked(_ st: Int) -> Bool {
        [SeerrClient.pending, SeerrClient.processing, SeerrClient.available].contains(st)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                RemoteImage(url: info?.result.backdrop ?? result.backdrop) { Rectangle().fill(Color.white.opacity(0.06)) }
                    .frame(maxWidth: .infinity).frame(height: 230).clipped()
                    .overlayCompat {
                        LinearGradient(gradient: Gradient(colors: [.black.opacity(0.35), .clear, .black]),
                                       startPoint: .top, endPoint: .bottom)
                    }
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let error { Text(error).foregroundColor(.secondary) }
                    if let info {
                        buttons(info)
                        if info.result.kind == "tv" && !info.seasons.isEmpty { seasonPicker(info) }
                        CastRowView(people: info.cast)
                        if !(info.result.overview.isEmpty) {
                            Text(info.result.overview).foregroundColor(.white.opacity(0.9))
                        }
                        credits(info)
                        if let c = info.collection { collectionRow(c) }
                    } else if error == nil {
                        HStack { Spacer(); OrangeSpinner(); Spacer() }
                    }
                }
                .padding(.horizontal)
                if !recs.isEmpty { SeerrRowView(title: "More like this", items: recs) }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat { await load() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            RemoteImage(url: info?.result.poster ?? result.poster) { Rectangle().fill(Color.white.opacity(0.08)) }
                .frame(width: 110, height: 165).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlayCompat(alignment: .topTrailing) { StatusDot(mark: state == "done" ? "req" : (info?.result.mark ?? result.mark)).padding(4) }
                .shadow(radius: 8)
            VStack(alignment: .leading, spacing: 6) {
                if let t = info?.tagline, !t.isEmpty {
                    Text(t).font(.caption.weight(.semibold)).foregroundColor(Color.ice).lineLimit(2)
                }
                Text(info?.result.title ?? result.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text(metaLine).font(.caption).foregroundColor(.secondary)
                badges
            }
        }
    }

    private var metaLine: String {
        var bits = [info?.result.year ?? result.year]
        if let info {
            if info.result.kind == "movie", let m = info.runtime { bits.append(m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m") }
            if info.result.kind == "tv", let n = info.numSeasons { bits.append(n == 1 ? "1 season" : "\(n) seasons") }
            bits += info.genres.prefix(2)
        }
        return bits.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if let c = info?.cert, !c.isEmpty { OutlineBadge(text: c) }
            if let s = ratings.rating(info?.imdbID) ?? scores.imdb { IMDbBadge(score: s) }
            if let rt = scores.rt {
                Text("RT \(rt)%").font(.system(size: 11, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
        }
    }

    @ViewBuilder
    private func buttons(_ info: SeerrTitle) -> some View {
        let st = info.result.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if st == SeerrClient.available || st == SeerrClient.partial {
                    if let lib = libItem {
                        Button { Task { await playFromLibrary(app, playback, lib) } } label: {
                            Label("Play", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .prominentButton()
                        NavigationLink(destination: LoadItemView(key: lib.ratingKey.value)) {
                            Text("Open").padding(.vertical, 4)
                        }
                        .borderedButton()
                    } else {
                        OrangeSpinner(size: 22)
                    }
                }
                if state == "done" {
                    Label("Requested", systemImage: "checkmark.circle.fill").foregroundColor(Color.ice)
                } else if info.result.kind == "movie" && (st == SeerrClient.pending || st == SeerrClient.processing) {
                    Label("Requested", systemImage: "clock.fill").foregroundColor(reqAmber)
                } else if canRequest(info) {
                    Button { send(info) } label: {
                        Label(state == "working" ? "Requesting…" : "Request", systemImage: "plus")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .prominentButton()
                    .disabled(state == "working" || (info.result.kind == "tv" && picked.isEmpty))
                } else if info.result.kind == "tv" {
                    Text("Every season is in your library or requested.").font(.footnote).foregroundColor(.secondary)
                }
                if let t = info.trailer {
                    Button { UIApplication.shared.open(t) } label: {
                        Label("Trailer", systemImage: "play.rectangle").padding(.vertical, 4)
                    }
                    .borderedButton()
                }
            }
            .largeControl()
            if let requestError { Text(requestError).font(.footnote).foregroundColor(.red) }
        }
    }

    private func canRequest(_ info: SeerrTitle) -> Bool {
        if info.result.kind == "movie" { return info.result.status != SeerrClient.available }
        return info.seasons.contains { !locked($0.status) }
    }

    private func seasonPicker(_ info: SeerrTitle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(info.seasons) { s in
                Button {
                    guard !locked(s.status), state != "done" else { return }
                    if picked.contains(s.number) { picked.remove(s.number) } else { picked.insert(s.number) }
                } label: {
                    HStack {
                        Image(systemName: (locked(s.status) || picked.contains(s.number)) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(locked(s.status) ? .secondary : Color.ice)
                        Text(s.name).foregroundColor(.white)
                        Text(["\(s.episodes) ep", SeerrClient.statusText[s.status]].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .plainButton()
            }
        }
    }

    @ViewBuilder
    private func credits(_ info: SeerrTitle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LinkLine(label: info.directors.count > 1 ? "Directors" : "Director", names: info.directors.map(\.name)) { i in
                PersonView(personID: info.directors[i].id, name: info.directors[i].name)
            }
            LinkLine(label: "Created by", names: info.creators.map(\.name)) { i in
                PersonView(personID: info.creators[i].id, name: info.creators[i].name)
            }
            LinkLine(label: "Writers", names: info.writers.map(\.name)) { i in
                PersonView(personID: info.writers[i].id, name: info.writers[i].name)
            }
            if let n = info.network {
                LinkLine(label: "Network", names: [n.name]) { _ in
                    SeerrGridView(title: n.name, kinds: ["tv"], source: .init(params: ["network": String(n.id)]))
                }
            }
            if info.result.kind == "movie", let s = info.studio {
                LinkLine(label: "Studio", names: [s.name]) { _ in
                    SeerrGridView(title: s.name, kinds: ["movie"], source: .init(params: ["studio": String(s.id)]))
                }
            }
            let provs = Array(info.providers.prefix(4))
            LinkLine(label: "Streaming on", names: provs.map(\.name)) { i in
                SeerrGridView(title: provs[i].name, kinds: info.result.kind == "movie" ? ["movie", "tv"] : ["tv", "movie"],
                              source: .init(params: ["watchProviders": String(provs[i].id), "watchRegion": SeerrClient.region]))
            }
        }
    }

    private func collectionRow(_ c: SeerrLink) -> some View {
        NavigationLink(destination: CollectionView(collectionID: c.id, name: c.name)) {
            HStack(spacing: 12) {
                RemoteImage(url: c.poster) { Color.white.opacity(0.08) }
                    .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Part of the \(c.name.replacingOccurrences(of: " Collection", with: "")) collection")
                        .font(.subheadline.bold()).foregroundColor(.white)
                    Text("See every movie in it").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        }
        .plainButton()
    }

    private func load() async {
        guard info == nil else { return }
        guard let sr = seerr(app) else { error = "Set your Seerr address in Settings first."; return }
        do {
            let t = try await sr.title(result.kind, result.id)
            info = t
            SeerrExtras.shared.put(t.result, imdb: t.imdbID, cert: t.cert)
            picked = Set(t.seasons.filter { !locked($0.status) }.map(\.number))
            if t.result.status == SeerrClient.available || t.result.status == SeerrClient.partial {
                libItem = await findInLibrary(app, t.result)
            }
            scores = await sr.scores(result.kind, result.id)
            recs = await sr.recommendations(result.kind, result.id)
        } catch {
            self.error = "Couldn't load from Seerr: \(error.localizedDescription)"
        }
    }

    private func send(_ info: SeerrTitle) {
        guard let sr = seerr(app) else { return }
        state = "working"
        requestError = nil
        let seasons: [Int]? = info.result.kind == "tv" ? Array(picked).sorted() : nil
        Task { @MainActor in
            do {
                try await sr.request(info.result, seasons: seasons)
                state = "done"
            } catch {
                state = ""
                requestError = "Couldn't request: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Actor / director

/// "Sat, Nov 15" (adds the year when it isn't this year).
func weekdayDate(_ s: String) -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    guard let d = df.date(from: String(s.prefix(10))) else { return s }
    let out = DateFormatter()
    out.dateFormat = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
        ? "EEE, MMM d" : "EEE, MMM d, yyyy"
    return out.string(from: d)
}

func niceDate(_ s: String) -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    guard let d = df.date(from: String(s.prefix(10))) else { return s }
    let out = DateFormatter()
    out.dateFormat = "MMM d, yyyy"
    return out.string(from: d)
}

struct PersonView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var extras = SeerrExtras.shared
    @ObservedObject private var ratings = IMDbRatings.shared
    let personID: Int?
    let name: String

    @State private var p: SeerrPersonDetails?
    @State private var error: String?
    @State private var group = ""
    @State private var sort = "new"
    @State private var showAll = false
    @State private var bioOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let p {
                    top(p)
                    if !p.known.isEmpty { SeerrRowView(title: "Known for", items: p.known) }
                    filmography(p)
                } else if let error {
                    Text(error).foregroundColor(.secondary).padding()
                } else {
                    HStack { Spacer(); OrangeSpinner(); Spacer() }.padding(.top, 60)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat { await load() }
    }

    private func top(_ p: SeerrPersonDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                RemoteImage(url: p.photo) {
                    ZStack { Rectangle().fill(Color.white.opacity(0.08)); Image(systemName: "person.fill").foregroundColor(.secondary) }
                }
                .frame(width: 110, height: 140).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name).font(.title2.bold())
                    let dept = ["Acting": "Actor", "Directing": "Director", "Writing": "Writer", "Production": "Producer"][p.dept] ?? p.dept
                    if !dept.isEmpty { Text(dept).font(.subheadline.bold()).foregroundColor(Color.ice) }
                    if !p.birthday.isEmpty { Text("Born \(niceDate(p.birthday))").font(.caption).foregroundColor(.secondary) }
                    if !p.place.isEmpty { Text(p.place).font(.caption).foregroundColor(.secondary) }
                    if !p.deathday.isEmpty { Text("Died \(niceDate(p.deathday))").font(.caption).foregroundColor(.secondary) }
                }
            }
            if !p.bio.isEmpty {
                Text(p.bio).font(.subheadline).foregroundColor(.white.opacity(0.9)).lineLimit(bioOpen ? nil : 5)
                if !bioOpen {
                    Button("More") { bioOpen = true }.font(.subheadline.bold()).foregroundColor(Color.ice).plainButton()
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func filmography(_ p: SeerrPersonDetails) -> some View {
        if !p.groups.isEmpty {
            let g = p.groups.first { $0.name == group } ?? p.groups[0]
            let list = sorted(g.items)
            let shown = showAll ? list : Array(list.prefix(40))
            VStack(alignment: .leading, spacing: 12) {
                Text("Filmography").font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(p.groups) { x in
                            Button { group = x.name; showAll = false } label: {
                                Chip(text: "\(x.name)  \(x.items.count)", on: x.name == g.name)
                            }
                            .plainButton()
                        }
                    }
                    .padding(.horizontal)
                }
                HStack(spacing: 8) {
                    Text("Sort").font(.caption).foregroundColor(.secondary)
                    ForEach([["new", "Newest"], ["imdb", "IMDb rating"], ["pop", "Popular"]], id: \.self) { kt in
                        Button {
                            sort = kt[0]
                            if kt[0] == "imdb" { for r in g.items { extras.want(r, seerr(app)) } }
                        } label: { Chip(text: kt[1], on: sort == kt[0]) }
                        .plainButton()
                    }
                }
                .padding(.horizontal)
                LazyVStack(spacing: 8) {
                    ForEach(shown, id: \.uid) { r in CreditRowView(result: r) }
                }
                .padding(.horizontal)
                if shown.count < list.count {
                    Button("Show all \(list.count)") { showAll = true }.borderedButton().padding(.horizontal)
                }
            }
        }
    }

    private func sorted(_ items: [SeerrResult]) -> [SeerrResult] {
        switch sort {
        case "imdb":
            return items.sorted { (ratings.rating(extras.get($0)?.imdb) ?? -1) > (ratings.rating(extras.get($1)?.imdb) ?? -1) }
        case "pop":
            return items.sorted { $0.votes > $1.votes }
        default:
            return items
        }
    }

    private func load() async {
        guard p == nil else { return }
        guard let sr = seerr(app) else { error = "Set your Seerr address in Settings first."; return }
        do {
            var pid = personID
            if pid == nil { pid = try await sr.findPerson(name) }
            guard let pid else { error = "Couldn't find \(name) in Seerr."; return }
            p = try await sr.person(pid)
        } catch {
            self.error = "Couldn't load from Seerr: \(error.localizedDescription)"
        }
    }
}

/// One title in a filmography, IMDb-app style: real poster, title with room to wrap, year and role,
/// age rating and IMDb score, and an in-library mark or Request button.
struct CreditRowView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var extras = SeerrExtras.shared
    @ObservedObject private var ratings = IMDbRatings.shared
    let result: SeerrResult
    @State private var requested = false
    @State private var working = false

    var body: some View {
        let e = extras.get(result)
        HStack(alignment: .center, spacing: 12) {
            NavigationLink(destination: seerrDestination(result)) {
                HStack(alignment: .top, spacing: 12) {
                    RemoteImage(url: result.poster) { Rectangle().fill(Color.white.opacity(0.08)) }
                        .frame(width: 64, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.subheadline.bold()).foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([result.year, result.role].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundColor(.secondary).lineLimit(2)
                        HStack(spacing: 6) {
                            if let c = e?.cert, !c.isEmpty { OutlineBadge(text: c) }
                            if let s = ratings.rating(e?.imdb) { IMDbBadge(score: s, size: 10) }
                            if result.kind == "tv" {
                                Text(result.episodes.map { "TV · \($0) ep" } ?? "TV").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .plainButton()
            let mark = requested ? "req" : result.mark
            if mark == "lib" {
                Image(systemName: "checkmark.circle.fill").foregroundColor(libGreen).font(.title3)
            } else if mark == "req" {
                Image(systemName: "clock.fill").foregroundColor(reqAmber).font(.title3)
            } else {
                Button {
                    guard let sr = seerr(app) else { return }
                    working = true
                    Task { @MainActor in
                        do { try await sr.request(result, seasons: nil); requested = true } catch {}
                        working = false
                    }
                } label: {
                    Image(systemName: working ? "hourglass" : "plus").font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black).frame(width: 34, height: 34).background(Circle().fill(Color.ice))
                }
                .plainButton()
                .disabled(working)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .onAppear { extras.want(result, seerr(app)) }
    }
}

// MARK: - Collection

struct CollectionView: View {
    @EnvironmentObject var app: AppState
    let collectionID: Int
    let name: String
    @State private var c: SeerrCollection?
    @State private var error: String?
    @State private var reqState = ""
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c {
                    RemoteImage(url: c.backdrop) { Rectangle().fill(Color.white.opacity(0.06)) }
                        .frame(maxWidth: .infinity).frame(height: 200).clipped()
                        .overlayCompat { LinearGradient(gradient: Gradient(colors: [.clear, .black]), startPoint: .top, endPoint: .bottom) }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(c.name).font(.title2.bold())
                        let have = c.parts.filter { $0.status == SeerrClient.available }.count
                        Text("\(c.parts.count) movies · \(have) in your library").font(.subheadline).foregroundColor(Color.ice)
                        if !c.overview.isEmpty { Text(c.overview).font(.subheadline).foregroundColor(.white.opacity(0.9)) }
                        let missing = c.parts.filter { $0.mark == nil }
                        if !missing.isEmpty || reqState == "done" {
                            Button { requestMissing(missing) } label: {
                                Label(reqState == "working" ? "Requesting…" : reqState == "done" ? "Requested" : "Request missing (\(missing.count))",
                                      systemImage: reqState == "done" ? "checkmark" : "plus")
                                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .prominentButton().largeControl()
                            .disabled(reqState != "")
                        }
                        if let note { Text(note).font(.footnote).foregroundColor(.secondary) }
                    }
                    .padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
                        ForEach(c.parts, id: \.uid) { r in SeerrPoster(result: r, width: 104) }
                    }
                    .padding(.horizontal)
                } else if let error {
                    Text(error).foregroundColor(.secondary).padding()
                } else {
                    HStack { Spacer(); OrangeSpinner(); Spacer() }.padding(.top, 60)
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat {
            guard c == nil, let sr = seerr(app) else { return }
            do { c = try await sr.collection(collectionID) } catch { self.error = error.localizedDescription }
        }
    }

    private func requestMissing(_ missing: [SeerrResult]) {
        guard let sr = seerr(app) else { return }
        reqState = "working"
        Task { @MainActor in
            var failed = 0
            for r in missing {
                do {
                    try await sr.request(r, seasons: nil)
                    if let i = c?.parts.firstIndex(where: { $0.uid == r.uid }) { c?.parts[i].status = SeerrClient.pending }
                } catch { failed += 1 }
            }
            reqState = "done"
            if failed > 0 { note = "\(failed) couldn't be requested." }
        }
    }
}
