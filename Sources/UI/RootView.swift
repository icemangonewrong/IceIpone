import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        Group {
            if !app.isSignedIn {
                SignInView()
            } else if app.server == nil {
                NavigationStack { ServerPickerView() }
            } else {
                MainTabs()
            }
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
        .fullScreenCover(isPresented: Binding(
            get: { playback.showPlayerUI },
            set: { shown in if !shown { Task { await playback.stop() } } }
        )) {
            PlayerScreen()
                .environmentObject(app)
                .environmentObject(playback)
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house") }
            NavigationStack { LibrariesView() }
                .tabItem { Label("Libraries", systemImage: "square.grid.2x2") }
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

// MARK: - Sign in

struct SignInView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("Logo")
                .resizable()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            Text("CarPlex").font(.largeTitle.bold())
            Text("Sign in with your Plex account. Safari will open; approve the sign-in, then come back here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button {
                Task { await app.signIn() }
            } label: {
                if app.signInInProgress {
                    HStack { ProgressView(); Text("Waiting for Plex…") }
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sign in with Plex").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(app.signInInProgress)
            .padding(.horizontal, 32)
            if let err = app.errorMessage {
                Text(err).foregroundStyle(.red).font(.footnote)
            }
            Spacer()
        }
    }
}

// MARK: - Server picker

struct ServerPickerView: View {
    @EnvironmentObject var app: AppState
    @State private var servers: [PlexResource] = []
    @State private var loading = true
    @State private var connectingID: String?
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Finding your servers…") }
            }
            ForEach(servers) { server in
                Button {
                    Task { await connect(server) }
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading) {
                            Text(server.name).font(.headline)
                            Text(server.owned == true ? "Your server" : "Shared with you")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connectingID == server.id { ProgressView() }
                    }
                }
                .disabled(connectingID != nil)
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            Section {
                Button("Sign out", role: .destructive) { app.signOut() }
            }
        }
        .navigationTitle("Choose server")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            servers = try await app.client.servers()
            if servers.isEmpty { error = "No servers found on this Plex account." }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func connect(_ server: PlexResource) async {
        connectingID = server.id
        defer { connectingID = nil }
        do {
            let saved = try await app.client.connect(to: server)
            app.saveServer(saved)
            await app.refreshHome()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
