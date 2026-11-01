import SwiftUI

struct SearchView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var results: [PlexItem] = []
    @State private var searching = false

    var body: some View {
        List(results) { item in
            NavigationLink(destination: ItemDetailView(item: item)) { SearchRow(item: item) }
        }
        .overlayCompat {
            if searching { OrangeSpinner() }
            else if !query.isEmpty && results.isEmpty { Text("No results").foregroundColor(.secondary) }
        }
        .navigationTitle("Search")
        .searchCompat(text: $query, prompt: "Movies and shows")
        .taskCompat(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 400_000_000) // wait for typing to pause
            if Task.isCancelled { return }
            searching = true
            let found = (try? await app.client.search(text)) ?? []
            if !Task.isCancelled { results = found.filter { !app.isExcluded($0) } }
            searching = false
        }
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

            Section(header: Text("Zoom"), footer: Text(app.zoomMode == "pinch"
                ? "Pinch to zoom to any size and drag with one finger to move the picture. Double tap goes back to normal."
                : "Double tap zooms in a little, again a little more, a third time fills the screen, and a fourth goes back to normal.")) {
                Picker("Zoom", selection: $app.zoomMode) {
                    Text("Double-tap steps").tag("steps")
                    Text("Pinch to zoom").tag("pinch")
                }
                .pickerStyle(SegmentedPickerStyle())
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
        }
        .navigationTitle("Settings")
        .onChange(of: app.excludedSections) { _ in
            Task { await app.refreshHome() }
        }
    }
}
