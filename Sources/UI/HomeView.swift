import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let err = app.errorMessage {
                    Text(err).foregroundColor(.red).padding(.horizontal)
                }

                if !app.continueWatching.isEmpty {
                    ItemRow(title: "Continue Watching", items: app.continueWatching, wide: true)
                } else if !app.isLoading {
                    Text("Nothing in progress.")
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                ForEach(app.visibleSections) { section in
                    if let items = app.recent[section.key], !items.isEmpty {
                        ItemRow(title: "Recently Added · \(section.title)", items: items, wide: false,
                                seeAll: section)
                    }
                }
            }
            .padding(.vertical)
        }
        .overlayCompat {
            if app.isLoading && app.continueWatching.isEmpty { OrangeSpinner() }
        }
        .navigationTitle(app.server?.name ?? "Home")
        .refreshableCompat { await app.refreshHome() }
        .taskCompat {
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
    /// Library to open (newest first) when the heading is tapped.
    var seeAll: PlexSection? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = seeAll {
                NavigationLink(destination: LibraryGridView(section: s,
                                                            sort: s.type == "show" ? .newestEpisode : .added)) {
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
    @ObservedObject private var ratings = IMDbRatings.shared   // redraw when IMDb scores arrive
    let item: PlexItem
    let width: CGFloat

    // Like Plex: the picture opens the item; under an episode the show name opens the show (all seasons) and
    // "S2 · E5" opens that season's episodes; under a season the show name opens the show.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink(destination: ItemDetailView(item: item)) { poster }
                .plainButton()
            if item.type == "episode", let show = item.showKey {
                NavigationLink(destination: LoadItemView(key: show)) { titleText }.plainButton()
            } else {
                NavigationLink(destination: ItemDetailView(item: item)) { titleText }.plainButton()
            }
            if let sub = item.displaySubtitle {
                let to = item.type == "episode" ? item.seasonKey : (item.type == "season" ? item.showKey : nil)
                if let key = to {
                    NavigationLink(destination: LoadItemView(key: key)) { subText(sub) }.plainButton()
                } else {
                    NavigationLink(destination: ItemDetailView(item: item)) { subText(sub) }.plainButton()
                }
            }
        }
        .frame(width: width)
    }

    private var titleText: some View {
        Text(item.displayTitle).font(.caption.bold()).lineLimit(1).foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subText(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var poster: some View {
            PosterImage(path: item.posterPath, width: width)
                .overlayCompat(alignment: .bottom) {
                    if let p = item.progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.6))
                                Rectangle().fill(Color.ice).frame(width: geo.size.width * p)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .overlayCompat(alignment: .topLeading) {
                    if item.type != "episode", let r = item.imdbRating {   // not on single episodes
                        IMDbBadge(score: r, size: width < 120 ? 10 : 11).padding(5)
                    }
                }
                .overlayCompat(alignment: .topTrailing) {
                    // Only for finished items; a rewatch in progress shows just the progress bar.
                    if item.isWatched && item.progress == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .palette(.white, Color.ice)
                            .padding(4)
                    }
                }
    }
}

struct PosterImage: View {
    @EnvironmentObject var app: AppState
    let path: String?
    let width: CGFloat

    var body: some View {
        RemoteImage(url: app.client.imageURL(path, width: Int(width * 2), height: Int(width * 3))) {
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.25))
                    Image(systemName: "film").foregroundColor(.secondary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
