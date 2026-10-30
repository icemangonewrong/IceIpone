import Foundation
import Security
import UIKit

/// App-wide state shared by the phone UI and the CarPlay screen.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let client: PlexClient

    @Published private(set) var token: String?
    @Published private(set) var server: SavedServer?
    @Published var sections: [PlexSection] = []
    @Published var continueWatching: [PlexItem] = []
    @Published var recent: [String: [PlexItem]] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var signInInProgress = false

    @Published var excludedSections: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedSections), forKey: Keys.excluded) }
    }
    @Published var pauseWhenMoving: Bool {
        didSet { UserDefaults.standard.set(pauseWhenMoving, forKey: Keys.pauseWhenMoving) }
    }
    /// How many minutes of video to keep downloaded ahead (stored on the phone, not in memory).
    @Published var bufferMinutes: Int {
        didSet { UserDefaults.standard.set(bufferMinutes, forKey: Keys.bufferMinutes) }
    }
    static let bufferChoices = [2, 5, 10, 20, 30]
    /// Tapping the video pauses/plays (otherwise a tap just shows or hides the controls).
    @Published var tapToPause: Bool {
        didSet { UserDefaults.standard.set(tapToPause, forKey: Keys.tapToPause) }
    }
    /// Audio delay in milliseconds for each audio output (Bluetooth car stereo, headphones...).
    /// Negative = sound earlier, which fixes Bluetooth lag.
    @Published var audioDelays: [String: Int] {
        didSet { UserDefaults.standard.set(audioDelays, forKey: Keys.audioDelays) }
    }

    private enum Keys {
        static let clientID = "clientIdentifier"
        static let server = "savedServer"
        static let excluded = "excludedSections"
        static let pauseWhenMoving = "pauseWhenMoving"
        static let bufferMinutes = "bufferMinutes"
        static let tapToPause = "tapToPause"
        static let audioDelays = "audioDelays"
        static let tokenAccount = "plexToken"
    }

    private init() {
        let defaults = UserDefaults.standard
        let clientID: String
        if let existing = defaults.string(forKey: Keys.clientID) {
            clientID = existing
        } else {
            clientID = UUID().uuidString
            defaults.set(clientID, forKey: Keys.clientID)
        }
        client = PlexClient(clientIdentifier: clientID)

        excludedSections = Set(defaults.stringArray(forKey: Keys.excluded) ?? [])
        pauseWhenMoving = defaults.object(forKey: Keys.pauseWhenMoving) as? Bool ?? true
        let savedBuffer = defaults.object(forKey: Keys.bufferMinutes) as? Int ?? 10
        bufferMinutes = AppState.bufferChoices.contains(savedBuffer) ? savedBuffer : 10
        tapToPause = defaults.object(forKey: Keys.tapToPause) as? Bool ?? false
        audioDelays = defaults.dictionary(forKey: Keys.audioDelays) as? [String: Int] ?? [:]

        token = Keychain.read(Keys.tokenAccount)
        if let data = defaults.data(forKey: Keys.server),
           let saved = try? JSONDecoder().decode(SavedServer.self, from: data) {
            server = saved
        }
        client.token = token
        client.server = server
        client.onServerURLChanged = { [weak self] updated in
            Task { @MainActor in self?.saveServer(updated) }
        }
    }

    var isSignedIn: Bool { token != nil }
    var visibleSections: [PlexSection] { sections.filter { !excludedSections.contains($0.key) } }

    func isExcluded(_ item: PlexItem) -> Bool {
        guard let sec = item.librarySectionID?.value, !sec.isEmpty else { return false }
        return excludedSections.contains(sec)
    }

    // MARK: - Sign in / out

    /// Opens Plex's sign-in page in Safari and waits for it to approve this app.
    func signIn() async {
        signInInProgress = true
        errorMessage = nil
        defer { signInInProgress = false }
        do {
            let pin = try await client.createPin()
            _ = await UIApplication.shared.open(client.authURL(for: pin))
            // Poll for up to 5 minutes.
            for _ in 0..<150 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let check = try await client.checkPin(id: pin.id)
                if let t = check.authToken, !t.isEmpty {
                    Keychain.save(t, account: Keys.tokenAccount)
                    token = t
                    client.token = t
                    return
                }
            }
            errorMessage = "Sign-in timed out. Try again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        Keychain.delete(Keys.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Keys.server)
        token = nil
        server = nil
        client.token = nil
        client.server = nil
        sections = []
        continueWatching = []
        recent = [:]
    }

    // MARK: - Server

    func saveServer(_ s: SavedServer) {
        server = s
        client.server = s
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Keys.server)
        }
    }

    func forgetServer() {
        UserDefaults.standard.removeObject(forKey: Keys.server)
        server = nil
        client.server = nil
        sections = []
        continueWatching = []
        recent = [:]
    }

    // MARK: - Home data

    func refreshHome() async {
        guard server != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            sections = try await client.sections()
            let cw = try await client.continueWatching()
            continueWatching = cw.filter { !isExcluded($0) }
            var newRecent: [String: [PlexItem]] = [:]
            for section in visibleSections {
                newRecent[section.key] = (try? await client.recentlyAdded(section: section.key)) ?? []
            }
            recent = newRecent
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Lighter refresh after watching something, so Continue Watching updates.
    func refreshContinueWatching() async {
        guard server != nil else { return }
        if let cw = try? await client.continueWatching() {
            continueWatching = cw.filter { !isExcluded($0) }
        }
    }
}

// MARK: - Keychain (keeps the Plex token out of plain settings)

enum Keychain {
    private static let service = "CarPlex"

    static func save(_ value: String, account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            // Some sideload signers break keychain access; fall back to app settings.
            UserDefaults.standard.set(value, forKey: "fallback." + account)
        }
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return UserDefaults.standard.string(forKey: "fallback." + account)
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "fallback." + account)
    }
}
