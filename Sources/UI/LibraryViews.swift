import SwiftUI

// MARK: - Library list

struct LibrariesView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List(app.visibleSections) { section in
            NavigationLink(value: section) {
                Label(section.title, systemImage: section.type == "show" ? "tv" : "film")
            }
        }
        .overlay {
            if app.visibleSections.isEmpty {
                Text(app.sections.isEmpty ? "Loading…" : "All libraries are hidden. Change that in Settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Libraries")
        .navigationDestination(for: PlexSection.self) { LibraryGridView(section: $0) }
        .navigationDestination(for: PlexItem.self) { ItemDetailView(item: $0) }
        .task { if app.sections.isEmpty { await app.refreshHome() } }
    }
}

// MARK: - One library as a poster grid

struct LibraryGridView: View {
    @EnvironmentObject var app: AppState
    let section: PlexSection

    enum Sort: String, CaseIterable, Identifiable {
        case title = "titleSort"
        case added = "addedAt:desc"
        case released = "originallyAvailableAt:desc"
        case lastViewed = "lastViewedAt:desc"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "Title"
            case .added: return "Recently added"
            case .released: return "Release date"
            case .lastViewed: return "Recently watched"
            }
        }
    }

    @State private var items: [PlexItem] = []
    @State private var total: Int?
    @State private var loading = false
    @State private var sort: Sort = .title
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
            if loading { ProgressView().padding() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(section.title)
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Unwatched only", isOn: $unwatchedOnly)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }
        .task(id: "\(sort.rawValue)-\(unwatchedOnly)") { await reload() }
        .refreshable { await reload() }
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

// MARK: - Detail screens

/// Routes to the right screen for a movie, show, season or episode.
struct ItemDetailView: View {
    let item: PlexItem

    var body: some View {
        switch item.type {
        case "show": ChildrenListView(parent: item, title: item.title ?? "Show")
        case "season": ChildrenListView(parent: item, title: item.title ?? "Season")
        default: PlayableDetailView(item: item)
        }
    }
}

struct PlayableDetailView: View {
    @EnvironmentObject var playback: PlaybackManager
    let item: PlexItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    PosterImage(path: item.posterPath, width: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.type == "episode" ? (item.title ?? "") : item.displayTitle)
                            .font(.title2.bold())
                        if let sub = item.displaySubtitle { Text(sub).foregroundStyle(.secondary) }
                        if let d = item.duration { Text("\(d / 60000) min").foregroundStyle(.secondary) }
                    }
                }
                HStack {
                    Button {
                        Task { await playback.play(item) }
                    } label: {
                        Label((item.viewOffset ?? 0) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    if (item.viewOffset ?? 0) > 0 {
                        Button {
                            Task { await playback.play(item, fromStart: true) }
                        } label: {
                            Label("From start", systemImage: "backward.end.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                if let s = item.summary, !s.isEmpty { Text(s) }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Seasons of a show, or episodes of a season.
struct ChildrenListView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playback: PlaybackManager
    let parent: PlexItem
    let title: String

    @State private var children: [PlexItem] = []
    @State private var loading = true

    var body: some View {
        List {
            if parent.type == "show" {
                Button {
                    Task { await playback.play(parent) }
                } label: {
                    Label("Play next episode", systemImage: "play.fill")
                }
            }
            ForEach(children) { child in
                if child.isPlayable {
                    Button {
                        Task { await playback.play(child) }
                    } label: { EpisodeRow(item: child) }
                    .buttonStyle(.plain)
                    .contextMenu { ItemMenu(item: child) }
                } else {
                    NavigationLink(value: child) {
                        HStack {
                            Text(child.title ?? "Season")
                            Spacer()
                            if child.isWatched {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                    .contextMenu { ItemMenu(item: child) }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(title)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        children = (try? await app.client.children(of: parent.ratingKey.value)) ?? []
        loading = false
    }
}

struct EpisodeRow: View {
    let item: PlexItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.index.map { "\($0). " } ?? "")\(item.title ?? "Episode")")
                    .font(.body.weight(.medium))
                if let d = item.duration {
                    Text("\(d / 60000) min").font(.caption).foregroundStyle(.secondary)
                }
                if let p = item.progress {
                    ProgressView(value: p).tint(.orange)
                }
            }
            Spacer()
            if item.isWatched {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "play.circle").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
