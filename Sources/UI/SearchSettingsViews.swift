import SwiftUI

struct SearchView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var results: [PlexItem] = []
    @State private var searching = false

    var body: some View {
        List(results) { item in
            NavigationLink(value: item) { SearchRow(item: item) }
        }
        .overlay {
            if searching { OrangeSpinner() }
            else if !query.isEmpty && results.isEmpty { Text("No results").foregroundStyle(.secondary) }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Movies and shows")
        .navigationDestination(for: PlexItem.self) { ItemDetailView(item: $0) }
        .task(id: query) {
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
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Connected to", value: app.server?.name ?? "—")
                if let url = app.server?.baseURL {
                    Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Change server") { app.forgetServer() }
            }

            Section {
                AccentPicker()
            } header: {
                Text("Accent color")
            } footer: {
                Text("Used for buttons, progress bars, the loading circle and highlights.")
            }

            Section {
                ForEach(app.sections) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !app.excludedSections.contains(section.key) },
                        set: { show in
                            if show { app.excludedSections.remove(section.key) }
                            else { app.excludedSections.insert(section.key) }
                        }
                    ))
                }
            } header: {
                Text("Libraries")
            } footer: {
                Text("Hidden libraries are left out of Home, Continue Watching, Libraries and Search.")
            }

            Section {
                Picker("Load ahead", selection: $app.bufferMinutes) {
                    ForEach(AppState.bufferChoices, id: \.self) { m in
                        Text("\(m) min").tag(m)
                    }
                }
            } header: {
                Text("Buffering")
            } footer: {
                Text("How much video to download ahead so it keeps playing through dead spots. It's saved on the phone's storage (not memory) and deleted when you stop watching. Also keeps loading while paused, so you can pause before a known dead zone and let it fill up.")
            }

            Section {
                Toggle("Pause when the screen is tapped", isOn: $app.tapToPause)
            } header: {
                Text("Player")
            } footer: {
                Text("When this is off, tapping the video just shows or hides the controls.")
            }

            Section {
                if app.audioDelays.isEmpty {
                    Text("No devices adjusted yet").foregroundStyle(.secondary)
                }
                ForEach(app.audioDelays.keys.sorted(), id: \.self) { device in
                    HStack {
                        Text(device)
                        Spacer()
                        let ms = app.audioDelays[device] ?? 0
                        Text("\(ms > 0 ? "+" : "")\(ms) ms").foregroundStyle(.secondary)
                        Button("Reset") { app.audioDelays[device] = nil }
                            .buttonStyle(.borderless)
                            .tint(Color.ice)
                    }
                }
            } header: {
                Text("Audio delay")
            } footer: {
                Text("Set from the player's audio delay button. Each Bluetooth device (like your truck) keeps its own setting and it's used automatically when that device is connected.")
            }

            Section {
                Toggle("Pause video when moving", isOn: $app.pauseWhenMoving)
            } header: {
                Text("Car screen")
            } footer: {
                Text("Applies when video shows on the CarPlay screen. Uses your location to tell when the vehicle is moving.")
            }

            Section {
                Button("Sign out", role: .destructive) { app.signOut() }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: app.excludedSections) {
            Task { await app.refreshHome() }
        }
    }
}
