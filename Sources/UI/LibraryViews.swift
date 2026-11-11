import SwiftUI

// MARK: - Library list

struct LibrariesView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List(app.visibleSections) { section in
            NavigationLink(destination: LibraryGridView(section: section)) {
                Label(section.title, systemImage: section.type == "show" ? "tv" : "film")
            }
        }
        .overlayCompat {
            if app.visibleSections.isEmpty {
                Text(app.sections.isEmpty ? "Loading…" : "All libraries are hidden. Change that in Settings.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Libraries")
        .taskCompat { if app.sections.isEmpty { await app.refreshHome() } }
    }
}

// MARK: - One library as a poster grid

struct LibraryGridView: View {
    @EnvironmentObject var app: AppState
    let section: PlexSection

    enum Sort: String, CaseIterable, Identifiable {
        case title = "titleSort"
        case newestEpisode = "episode.addedAt:desc"
        case added = "addedAt:desc"
        case released = "originallyAvailableAt:desc"
        case lastViewed = "lastViewedAt:desc"
        case imdb = "imdb"
        case popular = "popular"
        var id: String { rawValue }
        /// Sorted on the phone with IMDb's numbers (Plex can't sort by these), so the whole library is loaded.
        var local: Bool { self == .imdb || self == .popular }
        var label: String {
            switch self {
            case .title: return "Title"
            case .newestEpisode: return "Newest episode"
            case .added: return "Recently added"
            case .released: return "Release date"
            case .lastViewed: return "Recently watched"
            case .imdb: return "IMDb rating"
            case .popular: return "Popular (IMDb votes)"
            }
        }
    }

    @State private var items: [PlexItem] = []
    @State private var total: Int?
    @State private var loading = false
    @State private var sort: Sort

    init(section: PlexSection, sort: Sort = .title) {
        self.section = section
        _sort = State(initialValue: sort)
    }

    private var sorts: [Sort] { Sort.allCases.filter { $0 != .newestEpisode || section.type == "show" } }
    @State private var unwatchedOnly = false
    @State private var error: String?

    private let pageSize = 60
    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { item in
                    ItemTile(item: item, width: 105)
                        .onAppear {
                            if item == items.last { Task { await loadMore() } }
                        }
                }
            }
            .padding()
            if loading { OrangeSpinner().padding() }
            if let error { Text(error).foregroundColor(.red) }
        }
        .navigationTitle(section.title)
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(sorts) { Text($0.label).tag($0) }
                }
                Toggle("Unwatched only", isOn: $unwatchedOnly)
            } label: {
                Image(systemName: "line.horizontal.3.decrease.circle")
            }
        }
        .taskCompat(id: "\(sort.rawValue)-\(unwatchedOnly)") { await reload() }
        .refreshableCompat { await reload() }
    }

    private func reload() async {
        items = []
        total = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !loading else { return }
        if let total, items.count >= total { return }
        loading = true
        defer { loading = false }
        do {
            if sort.local {
                var all: [PlexItem] = []
                while true {
                    let page = try await app.client.items(section: section.key, sort: "titleSort",
                                                          unwatchedOnly: unwatchedOnly, start: all.count, size: 300)
                    all.append(contentsOf: page.items)
                    if page.items.count < 300 || (page.total.map { all.count >= $0 } ?? false) { break }
                }
                let imdb = IMDbRatings.shared
                let key: (PlexItem) -> Double = sort == .imdb
                    ? { $0.imdbRating ?? -1 }
                    : { Double(imdb.voteCount($0.imdbID) ?? -1) }
                let keyed = all.map { (key($0), $0) }
                items = keyed.sorted { $0.0 > $1.0 }.map { $0.1 }
                total = items.count
                error = nil
                return
            }
            let page = try await app.client.items(section: section.key, sort: sort.rawValue,
                                                  unwatchedOnly: unwatchedOnly,
                                                  start: items.count, size: pageSize)
            items.append(contentsOf: page.items)
            total = page.total ?? (page.items.count < pageSize ? items.count : nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
