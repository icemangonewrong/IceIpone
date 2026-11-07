import SwiftUI

// Your Seerr requests, saying plainly what's here, what's on its way and what isn't out yet
// (Seerr calls all of those "partially available").

struct EpisodeState: Hashable {
    let number: Int
    let name: String
    let airDate: String
    let state: String        // "have", "missing" (out but not here yet), "future" (not out yet)
}

struct SeasonProgress: Identifiable, Hashable {
    let number: Int
    let name: String
    let episodes: [EpisodeState]
    var id: Int { number }
}

private func day(_ s: String) -> Date? {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    return df.date(from: String(s.prefix(10)))
}

func shortDate(_ s: String) -> String {
    guard let d = day(s) else { return "" }
    let df = DateFormatter()
    df.dateFormat = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
        ? "MMM d" : "MMM d, yyyy"
    return df.string(from: d)
}

/// Per requested season: which episodes are in Plex, which are out but not here, which aren't out yet.
@MainActor func tvProgress(_ app: AppState, _ r: SeerrRequest) async -> [SeasonProgress] {
    guard let sr = seerr(app) else { return [] }
    var have = Set<String>()
    if let rk = r.ratingKey, let eps = try? await app.client.allEpisodes(showKey: rk) {
        for e in eps { have.insert("\(e.parentIndex ?? -1):\(e.index ?? -1)") }
    }
    let today = Calendar.current.startOfDay(for: Date())
    let numbers = r.seasonsRequested.isEmpty ? r.seasons.map(\.number) : r.seasonsRequested
    var out: [SeasonProgress] = []
    for n in numbers {
        let eps = (try? await sr.seasonEpisodes(r.tmdbID, n)) ?? []
        let rows = eps.map { e -> EpisodeState in
            let st: String
            if have.contains("\(n):\(e.number)") { st = "have" }
            else if let d = day(e.airDate), d <= today { st = "missing" }
            else { st = "future" }
            return EpisodeState(number: e.number, name: e.name, airDate: e.airDate, state: st)
        }
        out.append(SeasonProgress(number: n, name: r.seasons.first { $0.number == n }?.name ?? "Season \(n)", episodes: rows))
    }
    return out
}

func progressText(_ prog: [SeasonProgress]) -> (String, Color) {
    let all = prog.flatMap(\.episodes)
    if all.isEmpty { return ("", .secondary) }
    let have = all.filter { $0.state == "have" }.count
    let missing = all.filter { $0.state == "missing" }.count
    let future = all.filter { $0.state == "future" }
    let out = have + missing
    let next = future.map(\.airDate).filter { !$0.isEmpty }.min() ?? ""
    if missing == 0 && out > 0 && !future.isEmpty {
        return ("All \(out) episodes out so far are here · \(future.count) more coming" + (next.isEmpty ? "" : ", next \(shortDate(next))"),
                libGreen)
    }
    if missing == 0 && out > 0 { return ("All \(out) episodes are here", libGreen) }
    if out == 0 { return ("Not out yet" + (next.isEmpty ? "" : " · starts \(shortDate(next))"), .secondary) }
    var t = "\(have) of \(out) episodes out so far are here · \(missing) still coming in"
    if !future.isEmpty { t += " · \(future.count) not out yet" }
    return (t, reqAmber)
}

func requestState(_ r: SeerrRequest) -> (String, Color) {
    if r.reqStatus == 3 { return ("Declined", .red) }
    if r.status == SeerrClient.available { return ("Available", libGreen) }
    if r.status == SeerrClient.partial { return ("Partly available", .blue) }
    if r.kind == "movie", let d = day(r.date), d > Date() { return ("Not out yet", .gray) }
    if r.status == SeerrClient.processing || r.reqStatus == 2 { return ("Requested", reqAmber) }
    return ("Waiting for approval", .purple)
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.bold()).foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color))
    }
}

struct RequestsView: View {
    @EnvironmentObject var app: AppState
    @State private var items: [SeerrRequest]?
    @State private var error: String?
    @State private var filter = "all"

    private static let filters = [["all", "All"], ["waiting", "Requested"], ["partial", "Partly available"], ["available", "Available"]]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.filters, id: \.self) { f in
                            Button { filter = f[0] } label: {
                                Chip(text: items == nil ? f[1] : "\(f[1])  \(matching(f[0]).count)", on: filter == f[0])
                            }
                            .plainButton()
                        }
                    }
                    .padding(.horizontal)
                }
                if let error {
                    VStack(spacing: 10) {
                        Text(error).foregroundColor(.secondary)
                        Button("Try again") { self.error = nil; Task { await load() } }.borderedButton()
                    }
                    .frame(maxWidth: .infinity).padding()
                } else if items == nil {
                    HStack { Spacer(); OrangeSpinner(); Spacer() }.padding(.top, 60)
                } else if matching(filter).isEmpty {
                    Text("Nothing here.").foregroundColor(.secondary).padding()
                }
                LazyVStack(spacing: 8) {
                    ForEach(matching(filter)) { r in RequestRowView(request: r) }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("Requests")
        .taskCompat { if items == nil { await load() } }
        .refreshableCompat { await load() }
    }

    private func matching(_ k: String) -> [SeerrRequest] {
        let all = items ?? []
        switch k {
        case "waiting": return all.filter { $0.status != SeerrClient.available && $0.status != SeerrClient.partial && $0.reqStatus != 3 }
        case "partial": return all.filter { $0.status == SeerrClient.partial }
        case "available": return all.filter { $0.status == SeerrClient.available }
        default: return all
        }
    }

    private func load() async {
        guard let sr = seerr(app) else { error = "Set your Seerr address in Settings first."; return }
        do {
            let reqs = try await sr.myRequests()
            var filled = reqs
            await withTaskGroup(of: (Int, SeerrRequest).self) { group in
                for (i, r) in reqs.enumerated() { group.addTask { (i, await sr.fill(r)) } }
                for await (i, r) in group { filled[i] = r }
            }
            items = filled
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RequestRowView: View {
    @EnvironmentObject var app: AppState
    let request: SeerrRequest
    @State private var progress: [SeasonProgress]?

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: request.poster) { Rectangle().fill(Color.white.opacity(0.08)) }
                    .frame(width: 64, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title).font(.subheadline.bold()).foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(meta).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let progress {
                        let pt = progressText(progress)
                        if !pt.0.isEmpty { Text(pt.0).font(.caption.weight(.semibold)).foregroundColor(pt.1).fixedSize(horizontal: false, vertical: true) }
                    } else if needsProgress {
                        Text("Checking episodes…").font(.caption).foregroundColor(.secondary)
                    }
                    let rs = requestState(request)
                    StatusPill(text: rs.0, color: rs.1)
                    if !request.requestedAt.isEmpty {
                        Text("Requested \(niceDate(request.requestedAt))").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        }
        .plainButton()
        .taskCompat {
            if needsProgress && progress == nil { progress = await tvProgress(app, request) }
        }
    }

    private var needsProgress: Bool {
        request.kind == "tv" && request.status != SeerrClient.available && request.reqStatus != 3
    }

    private var meta: String {
        var bits = [request.year, request.kind == "movie" ? "Movie" : "TV show", request.cert]
        if request.kind == "tv" && !request.seasonsRequested.isEmpty {
            bits.append((request.seasonsRequested.count == 1 ? "Season " : "Seasons ")
                        + request.seasonsRequested.map(String.init).joined(separator: ", "))
        }
        if request.kind == "movie", let d = day(request.date), d > Date() { bits.append("comes out \(niceDate(request.date))") }
        return bits.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var destination: some View {
        if request.kind == "tv" {
            RequestStatusView(request: request, progress: progress)
        } else {
            seerrDestination(request.asResult)
        }
    }
}

/// A show's request, episode by episode: here / out but not here yet / not out yet.
struct RequestStatusView: View {
    @EnvironmentObject var app: AppState
    let request: SeerrRequest
    @State var progress: [SeasonProgress]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    RemoteImage(url: request.poster) { Rectangle().fill(Color.white.opacity(0.08)) }
                        .frame(width: 100, height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.title).font(.title2.bold())
                        let rs = requestState(request)
                        StatusPill(text: rs.0, color: rs.1)
                        if let progress {
                            let pt = progressText(progress)
                            Text(pt.0).font(.subheadline.weight(.semibold)).foregroundColor(pt.1)
                        }
                    }
                }
                HStack(spacing: 10) {
                    if let rk = request.ratingKey {
                        NavigationLink(destination: LoadItemView(key: rk)) {
                            Label("Open", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .prominentButton()
                    }
                    NavigationLink(destination: TitleView(result: request.asResult)) {
                        Text("Title page").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .borderedButton()
                }
                HStack(spacing: 14) {
                    legend("have", "In your library")
                    legend("missing", "On its way")
                    legend("future", "Not out yet")
                }
                if let progress {
                    ForEach(progress) { s in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.name).font(.title3.bold())
                            let have = s.episodes.filter { $0.state == "have" }.count
                            let out = s.episodes.filter { $0.state != "future" }.count
                            if s.episodes.isEmpty {
                                Text("No episode list yet.").font(.caption).foregroundColor(.secondary)
                            } else {
                                Text("\(have) of \(s.episodes.count) here · \(out) out so far").font(.caption).foregroundColor(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                                    ForEach(s.episodes, id: \.number) { e in EpisodeTile(e: e) }
                                }
                            }
                        }
                    }
                } else {
                    HStack { Spacer(); OrangeSpinner(); Spacer() }
                }
            }
            .padding()
        }
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        .taskCompat { if progress == nil { progress = await tvProgress(app, request) } }
    }

    private func legend(_ st: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            EpisodeTile.box(st).frame(width: 16, height: 12)
            Text(text).font(.caption2).foregroundColor(.secondary)
        }
    }
}

struct EpisodeTile: View {
    let e: EpisodeState

    static func box(_ st: String) -> some View {
        let fill: Color = st == "have" ? libGreen.opacity(0.75) : st == "missing" ? reqAmber.opacity(0.25) : .clear
        let edge: Color = st == "have" ? libGreen : st == "missing" ? reqAmber : Color.gray
        return RoundedRectangle(cornerRadius: 6).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(edge, style: StrokeStyle(lineWidth: 1.5, dash: st == "future" ? [4, 3] : [])))
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("E\(e.number)").font(.caption.bold())
            Text(e.state == "have" ? "✓" : e.state == "missing" ? "coming in" : (shortDate(e.airDate).isEmpty ? "TBA" : shortDate(e.airDate)))
                .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundColor(e.state == "future" ? .secondary : .white)
        .frame(maxWidth: .infinity).frame(height: 46)
        .background(Self.box(e.state))
    }
}
