import Foundation
import AVFoundation
import MediaPlayer
import CoreLocation

/// One player shared by the phone UI and the CarPlay screen.
/// Handles resume position, progress reporting to Plex, and "mark watched".
@MainActor
final class PlaybackManager: NSObject, ObservableObject {
    static let shared = PlaybackManager()

    @Published private(set) var player: AVPlayer?
    @Published private(set) var current: PlexItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    /// Whether the phone's player screen should be showing (stays up between episodes).
    @Published var showPlayerUI = false
    /// True when the CarPlay screen (jailbreak build) is showing the video.
    @Published var carScreenActive = false {
        didSet { updateMotionMonitoring() }
    }
    /// True while playback is held because the vehicle is moving.
    @Published private(set) var heldForMotion = false

    private var session = UUID().uuidString
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var reportTimer: Timer?
    private var endObserver: NSObjectProtocol?
    private var pendingResumeSeconds: Double = 0
    private let location = CLLocationManager()

    private var state: AppState { AppState.shared }
    private var client: PlexClient { AppState.shared.client }

    private override init() {
        super.init()
        location.delegate = self
        setupRemoteCommands()
    }

    // MARK: - Start / stop

    /// Plays an item. Movies/episodes play directly; a show plays its next episode.
    func play(_ item: PlexItem, fromStart: Bool = false) async {
        errorMessage = nil
        showPlayerUI = true
        var target = item
        if item.type == "show" {
            guard let next = try? await client.nextEpisode(showKey: item.ratingKey.value) else {
                errorMessage = "No episodes found."
                return
            }
            target = next
        }
        // Only fetch details if the list didn't include file info (saves a round trip).
        if target.Media == nil, let fresh = try? await client.metadata(target.ratingKey.value) { target = fresh }

        await stop(reportOnly: true)

        session = UUID().uuidString
        guard let url = client.streamURL(for: target, quality: state.quality, session: session) else {
            errorMessage = "Couldn't build a stream address."
            return
        }

        let avItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: avItem)
        newPlayer.allowsExternalPlayback = true
        avItem.preferredForwardBufferDuration = 0  // let AVPlayer start as soon as it can

        current = target
        duration = Double(target.duration ?? 0) / 1000
        currentTime = 0
        pendingResumeSeconds = fromStart ? 0 : Double(target.viewOffset ?? 0) / 1000
        // Don't resume in the last 2 minutes; start over instead.
        if duration > 0, pendingResumeSeconds > duration - 120 { pendingResumeSeconds = 0 }

        statusObservation = avItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        }
        rateObservation = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                self?.isPlaying = p.timeControlStatus != .paused
                self?.isBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.updateNowPlaying()
            }
        }
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                         queue: .main) { [weak self] t in
            Task { @MainActor in self?.timeTick(t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: avItem, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.finished() }
        }

        if pendingResumeSeconds > 1 {
            currentTime = pendingResumeSeconds
            newPlayer.seek(to: CMTime(seconds: pendingResumeSeconds, preferredTimescale: 600),
                           toleranceBefore: CMTime(seconds: 5, preferredTimescale: 1),
                           toleranceAfter: .zero)
            pendingResumeSeconds = 0
        }

        player = newPlayer
        isBuffering = true
        if !heldForMotion { newPlayer.play() }
        startReporting()
        updateNowPlaying()
    }

    /// Stops playback and saves the position to Plex.
    func stop(reportOnly: Bool = false) async {
        if !reportOnly { showPlayerUI = false }
        guard let player, let item = current else { return }
        let t = currentTime
        reportTimer?.invalidate()
        reportTimer = nil
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o) }
        timeObserver = nil
        statusObservation = nil
        rateObservation = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil

        self.player = nil
        self.current = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        isBuffering = false
        let durMs = Int(duration * 1000)
        let watched = duration > 0 && t / duration > 0.9
        let oldSession = session
        let c = client
        let refresh = !reportOnly
        // Report in the background so the next video doesn't wait on these calls.
        Task {
            await c.reportTimeline(item: item, state: "stopped", timeMs: Int(t * 1000), durationMs: durMs)
            if watched { await c.markWatched(item.ratingKey.value) }
            await c.stopTranscode(session: oldSession)
            if refresh { await AppState.shared.refreshContinueWatching() }
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if heldForMotion { return }
            player.play()
        } else {
            player.pause()
        }
        reportNow()
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        reportNow()
    }

    // MARK: - Internals

    private func itemStatusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            if pendingResumeSeconds > 1 {
                player?.seek(to: CMTime(seconds: pendingResumeSeconds, preferredTimescale: 600))
                currentTime = pendingResumeSeconds
                pendingResumeSeconds = 0
            }
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
        case .failed:
            errorMessage = item.error?.localizedDescription ?? "Playback failed."
        default:
            break
        }
    }

    private func timeTick(_ seconds: Double) {
        if seconds.isFinite { currentTime = seconds }
    }

    private func startReporting() {
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reportNow() }
        }
    }

    private func reportNow() {
        guard let item = current, let player else { return }
        let st = player.timeControlStatus == .paused ? "paused" : "playing"
        let t = Int(currentTime * 1000)
        let d = Int(duration * 1000)
        Task { await client.reportTimeline(item: item, state: st, timeMs: t, durationMs: d) }
        updateNowPlaying()
    }

    /// End of video: mark watched and roll into the next episode if there is one.
    private func finished() async {
        guard let item = current else { return }
        currentTime = duration
        let next = await nextEpisode(after: item)
        await stop(reportOnly: next != nil)
        if let next { await play(next, fromStart: true) }
    }

    private func nextEpisode(after item: PlexItem) async -> PlexItem? {
        guard item.type == "episode", let showKey = item.grandparentRatingKey?.value,
              let all = try? await client.children(of: showKey) else { return nil }
        // children(of: show) returns seasons; walk them in order to find the following episode.
        var foundCurrent = false
        for season in all where season.type == "season" {
            guard let eps = try? await client.children(of: season.ratingKey.value) else { continue }
            for ep in eps {
                if foundCurrent { return ep }
                if ep.ratingKey == item.ratingKey { foundCurrent = true }
            }
        }
        return nil
    }

    // MARK: - Lock screen / steering wheel controls

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.type == "episode" ? (item.title ?? "") : item.displayTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if item.type == "episode" { info[MPMediaItemPropertyArtist] = item.displayTitle + " · " + (item.displaySubtitle ?? "") }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Pause when moving (car screen only)

    private func updateMotionMonitoring() {
        if carScreenActive && state.pauseWhenMoving {
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            }
            location.desiredAccuracy = kCLLocationAccuracyBest
            location.startUpdatingLocation()
        } else {
            location.stopUpdatingLocation()
            heldForMotion = false
        }
    }

    fileprivate func speedChanged(_ metersPerSecond: Double) {
        // About 7 mph. Speed is -1 when unknown, which counts as stopped.
        let moving = metersPerSecond > 3
        if moving && !heldForMotion {
            heldForMotion = true
            player?.pause()
        } else if !moving && heldForMotion {
            heldForMotion = false
        }
    }
}

extension PlaybackManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let speed = locations.last?.speed else { return }
        Task { @MainActor in self.speedChanged(speed) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.updateMotionMonitoring() }
    }
}
