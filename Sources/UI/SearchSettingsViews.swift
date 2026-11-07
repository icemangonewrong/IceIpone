import SwiftUI

struct SearchView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var results: [PlexItem] = []
    @State private var searching = false
    @State private var others: [SeerrResult] = []
    @State private var othersNote: String?
    @State private var people: [SeerrPerson] = []

    var body: some View {
        List {
            Section {
                ForEach(results) { item in
                    NavigationLink(destination: ItemDetailView(item: item)) { SearchRow(item: item) }
                }
            }
            if !people.isEmpty {
                Section(header: Text("People")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(people, id: \.uid) { p in
                                NavigationLink(destination: PersonView(personID: p.id, name: p.name)) {
                                    CastCard(person: p, width: 92)
                                }
                                .plainButton()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if !others.isEmpty || othersNote != nil {
                Section(header: Text("Not in your library · request with Seerr")) {
                    if let note = othersNote {
                        Text(note).font(.footnote).foregroundColor(.secondary)
                    }
                    ForEach(others) { r in
                        NavigationLink(destination: seerrDestination(r)) { SeerrRow(result: r) }
                    }
                }
            }
        }
        .overlayCompat {
            if searching { OrangeSpinner() }
            else if !query.isEmpty && results.isEmpty && others.isEmpty && othersNote == nil {
                Text("No results").foregroundColor(.secondary)
            }
        }
        .navigationTitle("Search")
        .searchCompat(text: $query, prompt: "Movies and shows")
        .taskCompat(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { results = []; others = []; people = []; othersNote = nil; return }
            try? await Task.sleep(nanoseconds: 400_000_000) // wait for typing to pause
            if Task.isCancelled { return }
            searching = true
            async let plex = (try? await app.client.search(text)) ?? []
            var seerrFound: [SeerrResult] = []
            var note: String?
            var foundPeople: [SeerrPerson] = []
            if let sr = seerr(app) {
                foundPeople = Array(((try? await sr.searchPeople(text)) ?? []).sorted { ($0.photo != nil ? 0 : 1) < ($1.photo != nil ? 0 : 1) }.prefix(12))
                do {
                    // Things already in Plex show up in the results above, so leave them out here.
                    seerrFound = try await sr.search(text).filter { $0.status != SeerrClient.available }
                    if seerrFound.isEmpty { note = "Nothing else found." }
                } catch {
                    note = "Couldn't search Seerr: \(error.localizedDescription)"
                }
            }
            let found = await plex
            if !Task.isCancelled {
                results = found.filter { !app.isExcluded($0) }
                others = seerrFound
                othersNote = note
                people = foundPeople
            }
            searching = false
        }
    }
}

struct SeerrRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var extras = SeerrExtras.shared
    @ObservedObject private var ratings = IMDbRatings.shared
    let result: SeerrResult

    var body: some View {
        let e = extras.get(result)
        HStack(spacing: 12) {
            RemoteImage(url: result.poster) { Color.white.opacity(0.08) }
                .frame(width: 50, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.headline)
                Text([result.year, e?.cert ?? "", result.kindText, result.statusText ?? ""].filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    .font(.caption).foregroundColor(.secondary)
                if let s = ratings.rating(e?.imdb) { IMDbBadge(score: s, size: 10) }
            }
        }
        .onAppear { extras.want(result, seerr(app)) }
    }
}

struct SearchRow: View {
    let item: PlexItem

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(path: item.posterPath, width: 50)
            VStack(alignment: .leading) {
                Text(item.type == "episode" ? (item.title ?? "") : item.displayTitle).font(.headline)
                Text(item.type == "episode" ? "\(item.displayTitle) · \(item.displaySubtitle ?? "")"
                                            : (item.displaySubtitle ?? (item.type ?? "")))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var crashNote: String? = CrashNote.last

    var body: some View {
        Form {
            if let crash = crashNote {
                Section(header: Text("Last crash"), footer: Text("Saved when Ice last crashed. Send a screenshot of this to fix it.")) {
                    Text(crash).font(.system(size: 11, design: .monospaced)).lineLimit(14).selectableText()
                    Button(action: { CrashNote.clear(); crashNote = nil }) { Text("Clear").foregroundColor(.red) }
                }
            }

            Section(header: Text("Server")) {
                HStack {
                    Text("Connected to")
                    Spacer()
                    Text(app.server?.name ?? "—").foregroundColor(.secondary)
                }
                if let url = app.server?.baseURL {
                    Text(url).font(.caption).foregroundColor(.secondary).selectableText()
                }
                Button("Change server") { app.forgetServer() }
            }

            Section(header: Text("Accent color"), footer: Text("Used for buttons, progress bars, the loading circle and highlights.")) {
                AccentPicker()
            }

            Section(header: Text("Libraries"), footer: Text("Hidden libraries are left out of Home, Continue Watching, Libraries and Search.")) {
                ForEach(app.sections) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !app.excludedSections.contains(section.key) },
                        set: { show in
                            if show { app.excludedSections.remove(section.key) }
                            else { app.excludedSections.insert(section.key) }
                        }
                    ))
                }
            }

            Section(header: Text("Buffering"), footer: Text("How much video to download ahead so it keeps playing through dead spots. It's saved on the phone's storage (not memory) and deleted when you stop watching. Also keeps loading while paused, so you can pause before a known dead zone and let it fill up.")) {
                Picker("Load ahead", selection: $app.bufferMinutes) {
                    ForEach(AppState.bufferChoices, id: \.self) { m in
                        Text("\(m) min").tag(m)
                    }
                }
            }

            Section(header: Text("Player"), footer: Text("When this is off, tapping the video just shows or hides the controls.")) {
                Toggle("Pause when the screen is tapped", isOn: $app.tapToPause)
            }

            Section(header: Text("Zoom"), footer: Text("Double tap the video to zoom in steps (a 4th double tap goes back to normal). Pinch to zoom further and drag to move it.")) {
                EmptyView()
            }

            Section(header: Text("Audio delay"), footer: Text("Set from the player's audio delay button. Each Bluetooth device (like your truck) keeps its own setting and it's used automatically when that device is connected.")) {
                if app.audioDelays.isEmpty {
                    Text("No devices adjusted yet").foregroundColor(.secondary)
                }
                ForEach(app.audioDelays.keys.sorted(), id: \.self) { device in
                    HStack {
                        Text(device)
                        Spacer()
                        let ms = app.audioDelays[device] ?? 0
                        Text("\(ms > 0 ? "+" : "")\(ms) ms").foregroundColor(.secondary)
                        Button("Reset") { app.audioDelays[device] = nil }
                            .borderlessButton()
                            .iceTint(Color.ice)
                    }
                }
            }

            Section(header: Text("Car screen"), footer: Text("Applies when video shows on the CarPlay screen. Uses your location to tell when the vehicle is moving.")) {
                Toggle("Pause video when moving", isOn: $app.pauseWhenMoving)
            }

            Section {
                Button(action: { app.signOut() }) { Text("Sign out").foregroundColor(.red) }
            }

            SeerrSettingsSection()

            Section(header: Text("About"), footer: Text("The newest build number is shown on the download page.")) {
                Text("Ice for iPhone  ·  build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
                Button("Check for updates") {
                    if let url = URL(string: "https://github.com/icemangonewrong/IceIpone/releases/latest") {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: app.excludedSections) { _ in
            Task { await app.refreshHome() }
        }
    }
}


struct SeerrSettingsSection: View {
    @EnvironmentObject var app: AppState
    @State private var url = SeerrClient.savedURL
    @State private var result = ""

    var body: some View {
        Section(header: Text("Requests (Seerr)"),
                footer: Text("Search shows everything, not just your library, and lets you request what's missing through Seerr. Ice signs in with your Plex account. Over WireGuard, the address is usually http://10.66.66.1:5056.")) {
            TextField("http://10.66.66.1:5056", text: $url, onCommit: { SeerrClient.savedURL = url })
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Test connection") {
                SeerrClient.savedURL = url
                guard let sr = SeerrClient(url: url, plexToken: app.token) else { result = "Enter the address first."; return }
                result = "Checking…"
                Task { @MainActor in
                    do { result = "Connected as \(try await sr.test())" } catch { result = error.localizedDescription }
                }
            }
            if !result.isEmpty { Text(result).font(.footnote).foregroundColor(.secondary) }
        }
        .onDisappear { SeerrClient.savedURL = url }
    }
}
