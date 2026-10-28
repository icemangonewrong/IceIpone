import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let err = app.errorMessage {
                    Text(err).foregroundStyle(.red).padding(.horizontal)
                }

                if !app.continueWatching.isEmpty {
                    ItemRow(title: "Continue Watching", items: app.continueWatching, wide: true)
                } else if !app.isLoading {
                    Text("Nothing in progress.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                ForEach(app.visibleSections) { section in
                    if let items = app.recent[section.key], !items.isEmpty {
                        ItemRow(title: "Recently Added · \(section.title)", items: items, wide: false)
                    }
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if app.isLoading && app.continueWatching.isEmpty { OrangeSpinner() }
        }
        .navigationTitle(app.server?.name ?? "Home")
        .navigationDestination(for: PlexItem.self) { ItemDetailView(item: $0) }
        .refreshable { await app.refreshHome() }
        .task {
            if app.sections.isEmpty { await app.refreshHome() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await app.refreshContinueWatching() }
        }
    }
}

/// A titled horizontal row of posters.
struct ItemRow: View {
    let title: String
    let items: [PlexItem]
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        ItemTile(item: item, width: wide ? 130 : 110)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Poster tile. Tapping always opens the info page.
struct ItemTile: View {
    let item: PlexItem
    let width: CGFloat

    var body: some View {
        NavigationLink(value: item) { tileBody }
            .buttonStyle(.plain)
    }

    private var tileBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(path: item.posterPath, width: width)
                .overlay(alignment: .bottom) {
                    if let p = item.progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.6))
                                Rectangle().fill(.orange).frame(width: geo.size.width * p)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Only for finished items; a rewatch in progress shows just the progress bar.
                    if item.isWatched && item.progress == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .orange)
                            .padding(4)
                    }
                }
            Text(item.displayTitle)
                .font(.caption.bold())
                .lineLimit(1)
            if let sub = item.displaySubtitle {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

struct PosterImage: View {
    @EnvironmentObject var app: AppState
    let path: String?
    let width: CGFloat

    var body: some View {
        AsyncImage(url: app.client.imageURL(path, width: Int(width * 2), height: Int(width * 3))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.25))
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
