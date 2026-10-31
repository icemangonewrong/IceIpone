import SwiftUI

// MARK: - Router

/// Opens the right info page for a movie, episode, show or season.
struct ItemDetailView: View {
    let item: PlexItem

    var body: some View {
        switch item.type {
        case "show": ShowDetailView(item: item)
        case "season": SeasonDetailView(item: item)
        default: PlayableDetailView(item: item)
        }
    }
}

// MARK: - Movie / episode

struct PlayableDetailView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playback: PlaybackManager
    let item: PlexItem

    @State private var full: PlexItem?
    @State private var seasonEpisodes: [PlexItem] = []
    @State private var working = false

    private var d: PlexItem { full ?? item }
    private var isEpisode: Bool { d.type == "episode" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Backdrop(path: isEpisode ? (d.thumb ?? d.grandparentArt ?? d.art) : (d.art ?? d.thumb))

                VStack(alignment: .leading, spacing: 18) {
                    header
                    PlayButtons(item: d)
                    WatchedButton(item: d, working: $working) { await load() }

                    if let s = d.summary, !s.isEmpty {
                        Text(s).font(.body).foregroundColor(.white.opacity(0.9))
                    }

                    CreditsView(item: d)
                    FileInfoView(item: d)

                    if isEpisode, seasonEpisodes.count > 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Season \(d.parentIndex ?? 0)").font(.title3.bold())
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        ForEach(seasonEpisodes) { ep in
                                            NavigationLink(destination: ItemDetailView(item: ep)) {
                                                EpisodeCard(item: ep, isCurrent: ep == d)
                                            }
                                            .plainButton()
                                            .id(ep.id)
                                        }
                                    }
                                }
                                .onAppear { proxy.scrollTo(d.id, anchor: .center) }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat { await load() }
        .onChange(of: playback.showPlayerUI) { shown in
            // Came back from the player: refresh progress / watched state.
            if !shown { Task { await load() } }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            if !isEpisode {
                PosterImage(path: d.thumb, width: 110)
                    .shadow(radius: 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                if isEpisode {
                    Text(d.grandparentTitle ?? "").font(.subheadline.weight(.semibold)).foregroundColor(Color.ice)
                }
                Text(d.title ?? "").font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                if isEpisode, let s = d.parentIndex, let e = d.index {
                    Text("Season \(s) · Episode \(e)").foregroundColor(.secondary)
                }
                MetaLine(item: d)
                if let genres = d.Genre, !genres.isEmpty {
                    Text(genres.prefix(4).map(\.tag).joined(separator: " · "))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func load() async {
        if let fresh = try? await app.client.metadata(item.ratingKey.value) { full = fresh }
        if isEpisode, let season = d.parentRatingKey?.value {
            seasonEpisodes = (try? await app.client.children(of: season)) ?? []
        }
    }
}

// MARK: - Show

struct ShowDetailView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playback: PlaybackManager
    let item: PlexItem

    @State private var full: PlexItem?
    @State private var seasons: [PlexItem] = []
    @State private var next: PlexItem?
    @State private var working = false

    private var d: PlexItem { full ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Backdrop(path: d.art ?? d.thumb)

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .bottom, spacing: 14) {
                        PosterImage(path: d.thumb, width: 110).shadow(radius: 8)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.title ?? "").font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                            MetaLine(item: d, seasons: seasons.count)
                            if let genres = d.Genre, !genres.isEmpty {
                                Text(genres.prefix(4).map(\.tag).joined(separator: " · "))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }

                    if let next {
                        Button {
                            Task { await playback.play(next) }
                        } label: {
                            VStack(spacing: 2) {
                                Label((next.viewOffset ?? 0) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                                    .font(.headline)
                                Text(episodeCode(next) + (next.title.map { " · " + $0 } ?? ""))
                                    .font(.caption).lineLimit(1).opacity(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .prominentButton()
                        .largeControl()
                    }

                    WatchedButton(item: d, working: $working) { await load() }

                    if let s = d.summary, !s.isEmpty {
                        Text(s).foregroundColor(.white.opacity(0.9))
                    }

                    if !seasons.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Seasons").font(.title3.bold())
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(seasons) { season in
                                        NavigationLink(destination: ItemDetailView(item: season)) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                PosterImage(path: season.thumb ?? d.thumb, width: 105)
                                                    .overlayCompat(alignment: .topTrailing) {
                                                        if season.isWatched {
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .palette(.white, Color.ice).padding(4)
                                                        }
                                                    }
                                                Text(season.title ?? "Season").font(.caption.bold()).lineLimit(1)
                                                if let n = season.leafCount {
                                                    Text("\(n) episodes").font(.caption2).foregroundColor(.secondary)
                                                }
                                            }
                                            .frame(width: 105)
                                        }
                                        .plainButton()
                                    }
                                }
                            }
                        }
                    }

                    CreditsView(item: d)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat { await load() }
        .onChange(of: playback.showPlayerUI) { shown in
            if !shown { Task { await load() } }
        }
    }

    private func load() async {
        let key = item.ratingKey.value
        if let fresh = try? await app.client.metadata(key) { full = fresh }
        seasons = ((try? await app.client.children(of: key)) ?? []).filter { $0.type == "season" }
        next = try? await app.client.nextEpisode(showKey: key)
    }
}

// MARK: - Season

struct SeasonDetailView: View {
    @EnvironmentObject var app: AppState
    let item: PlexItem

    @State private var full: PlexItem?
    @State private var episodes: [PlexItem] = []
    @State private var loading = true
    @State private var working = false
    @EnvironmentObject var playback: PlaybackManager

    private var d: PlexItem { full ?? item }

    var body: some View {
        List {
            Section {
                HStack(alignment: .bottom, spacing: 14) {
                    PosterImage(path: d.thumb, width: 90)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.parentTitle ?? "").font(.subheadline.weight(.semibold)).foregroundColor(Color.ice)
                        Text(d.title ?? "Season").font(.title2.bold())
                        Text("\(episodes.count) episodes").foregroundColor(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                WatchedButton(item: d, working: $working) { await load() }
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(episodes) { ep in
                    NavigationLink(destination: ItemDetailView(item: ep)) { EpisodeRow(item: ep) }
                }
            }
        }
        .listStyle(PlainListStyle())
        .overlayCompat { if loading && episodes.isEmpty { OrangeSpinner() } }
        .navigationTitle(d.title ?? "Season")
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat { await load() }
        .refreshableCompat { await load() }
        .onChange(of: playback.showPlayerUI) { shown in
            if !shown { Task { await load() } }
        }
    }

    private func load() async {
        loading = true
        if let fresh = try? await app.client.metadata(item.ratingKey.value) { full = fresh }
        episodes = (try? await app.client.children(of: item.ratingKey.value)) ?? []
        loading = false
    }
}

// MARK: - Pieces

/// Wide background image that fades into the page.
private struct Backdrop: View {
    @EnvironmentObject var app: AppState
    let path: String?

    var body: some View {
        RemoteImage(url: app.client.imageURL(path, width: 1280, height: 720)) {
                Rectangle().fill(Color.white.opacity(0.06))
            }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .clipped()
        .overlayCompat {
            LinearGradient(gradient: Gradient(colors: [.black.opacity(0.35), .clear, .black]),
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// "2023 · PG-13 · 1h 52m · ★ 8.1"
private struct MetaLine: View {
    let item: PlexItem
    var seasons: Int = 0

    private var text: String {
        var parts: [String] = []
        if let y = item.year { parts.append(String(y)) }
        if let r = item.contentRating, !r.isEmpty { parts.append(r) }
        if item.type == "show" {
            if seasons > 0 { parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons") }
        } else if let d = item.duration {
            parts.append(runtimeString(d))
        }
        if let score = item.audienceRating ?? item.rating { parts.append(String(format: "★ %.1f", score)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Text(text).font(.subheadline).foregroundColor(.secondary)
    }
}

/// Resume / Play from start, with time left and a progress bar.
private struct PlayButtons: View {
    @EnvironmentObject var playback: PlaybackManager
    let item: PlexItem

    var body: some View {
        let inProgress = (item.viewOffset ?? 0) > 0 && item.progress != nil
        VStack(alignment: .leading, spacing: 10) {
            if inProgress, let p = item.progress {
                HStack(spacing: 10) {
                    ProgressView(value: p).iceTint(Color.ice)
                    if let dur = item.duration, let off = item.viewOffset {
                        Text("\(runtimeString(max(dur - off, 0))) left")
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                Button {
                    Task { await playback.play(item) }
                } label: {
                    Label(inProgress ? "Resume" : "Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .prominentButton()

                if inProgress {
                    Button {
                        Task { await playback.play(item, fromStart: true) }
                    } label: {
                        Label("From start", systemImage: "backward.end.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .borderedButton()
                }
            }
            .largeControl()
        }
    }
}

/// Mark watched / unwatched (works for movies, episodes, whole seasons and shows).
private struct WatchedButton: View {
    @EnvironmentObject var app: AppState
    let item: PlexItem
    @Binding var working: Bool
    let reload: () async -> Void

    var body: some View {
        let watched = item.isWatched && item.progress == nil
        Button {
            Task {
                working = true
                if watched { await app.client.markUnwatched(item.ratingKey.value) }
                else { await app.client.markWatched(item.ratingKey.value) }
                await reload()
                await app.refreshContinueWatching()
                working = false
            }
        } label: {
            HStack(spacing: 8) {
                if working { OrangeSpinner(size: 16) }
                else { Image(systemName: watched ? "checkmark.circle.fill" : "circle") }
                Text(watched ? "Watched" : "Mark as watched")
            }
            .font(.subheadline.weight(.semibold))
        }
        .borderedButton()
        .iceTint(watched ? Color.ice : .gray)
        .disabled(working)
    }
}

/// Director and cast.
private struct CreditsView: View {
    let item: PlexItem

    var body: some View {
        let directors = (item.Director ?? []).map(\.tag)
        let cast = Array((item.Role ?? []).prefix(10))
        if !directors.isEmpty || !cast.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !directors.isEmpty {
                    Text("Directed by ").foregroundColor(.secondary) + Text(directors.joined(separator: ", "))
                }
                if !cast.isEmpty {
                    Text("Cast").font(.headline).padding(.top, 4)
                    ForEach(cast, id: \.self) { r in
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.tag).font(.subheadline.weight(.medium))
                            if let role = r.role, !role.isEmpty {
                                Text(role).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .font(.subheadline)
        }
    }
}

/// What you're about to stream: resolution, codecs, size.
private struct FileInfoView: View {
    let item: PlexItem

    var body: some View {
        if let m = item.Media?.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("File").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Video", [resolution(m), m.videoDynamicRange.flatMap { $0 == "SDR" ? nil : $0 },
                                  m.videoCodec?.uppercased()])
                    row("Audio", [m.audioCodec?.uppercased(), m.audioChannels.map { channels($0) }])
                    row("File", [m.container?.uppercased(),
                                 item.firstPart?.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                                 m.bitrate.map { String(format: "%.1f Mbps", Double($0) / 1000) }])
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ values: [String?]) -> some View {
        let text = values.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !text.isEmpty {
            GridRow {
                Text(label).foregroundColor(.secondary)
                Text(text)
            }
        }
    }

    private func resolution(_ m: PlexMedia) -> String? {
        guard let r = m.videoResolution?.lowercased() else { return nil }
        switch r {
        case "4k": return "4K"
        case "sd": return "SD"
        default: return r.hasSuffix("p") ? r : r + "p"
        }
    }

    private func channels(_ n: Int) -> String {
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n) ch"
        }
    }
}

/// Episode in the "Season N" row on an episode page.
private struct EpisodeCard: View {
    @EnvironmentObject var app: AppState
    let item: PlexItem
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: app.client.imageURL(item.thumb, width: 400, height: 225)) {
                Rectangle().fill(Color.white.opacity(0.08))
            }
            .frame(width: 170, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ice, lineWidth: isCurrent ? 2 : 0))
            .overlayCompat(alignment: .bottom) {
                if let p = item.progress {
                    ProgressView(value: p).iceTint(Color.ice).padding(.horizontal, 6).padding(.bottom, 4)
                }
            }
            .overlayCompat(alignment: .topTrailing) {
                if item.isWatched && item.progress == nil {
                    Image(systemName: "checkmark.circle.fill").palette(.white, Color.ice).padding(4)
                }
            }
            Text("\(item.index.map { "\($0). " } ?? "")\(item.title ?? "")")
                .font(.caption.bold()).lineLimit(1)
        }
        .frame(width: 170)
    }
}

/// Episode row in a season list.
struct EpisodeRow: View {
    @EnvironmentObject var app: AppState
    let item: PlexItem

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.client.imageURL(item.thumb, width: 320, height: 180)) {
                Rectangle().fill(Color.white.opacity(0.08))
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlayCompat(alignment: .bottom) {
                if let p = item.progress {
                    ProgressView(value: p).iceTint(Color.ice).padding(.horizontal, 4).padding(.bottom, 3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.index.map { "\($0). " } ?? "")\(item.title ?? "Episode")")
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                if let d = item.duration {
                    Text(runtimeString(d)).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if item.isWatched && item.progress == nil {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Color.ice)
            }
        }
        .contentShape(Rectangle())
    }
}

/// "S2 · E4"
func episodeCode(_ item: PlexItem) -> String {
    [item.parentIndex.map { "S\($0)" }, item.index.map { "E\($0)" }].compactMap { $0 }.joined(separator: " · ")
}

/// 6720000 ms -> "1h 52m"
func runtimeString(_ ms: Int) -> String {
    let mins = max(ms / 60000, 0)
    if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
    return "\(mins)m"
}
