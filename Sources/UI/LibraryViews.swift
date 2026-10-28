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
            if loading { OrangeSpinner().padding() }
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
