import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import CoreLocation
import VLCKitSPM

/// One player shared by the phone UI and the CarPlay screen.
///
/// Plays the original file (true direct play, like the Plex app) with VLC, through
/// `StreamProxy`, which keeps minutes of video cached on the phone so dead zones don't
/// stop playback. Also handles resume, progress sync to Plex and "mark watched".
@MainActor
final class PlaybackManager: NSObject, ObservableObject {
    static let shared = PlaybackManager()

    struct Track: Identifiable, Hashable {
        let id: Int32
        let name: String
    }

    /// A video is loaded (playing, paused or loading).
    @Published private(set) var isActive = false
    @Published private(set) var current: PlexItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// Seconds of video downloaded past the current position.
    @Published private(set) var bufferedAhead: Double = 0
    @Published private(set) var errorMessage: String?
    /// The download from Plex is failing (no signal). Playback continues from the cache.
    @Published private(set) var offline = false
    /// Out of signal AND out of cached video: we're waiting for coverage.
    @Published private(set) var waitingForSignal = false
    /// Whether the phone's player screen should be showing (stays up between episodes).
    @Published var showPlayerUI = false {
        didSet { applyZoom() }
    }
    /// True when the CarPlay screen (jailbreak build) is showing the video.
    @Published var carScreenActive = false {
        didSet { updateMotionMonitoring(); applyZoom() }
    }
    /// True while playback is held because the vehicle is moving.
    @Published private(set) var heldForMotion = false

    /// The episode after the current one (nil for movies or the last episode).
    @Published private(set) var nextItem: PlexItem?
    /// Intro / credits currently on screen that can be skipped.
    @Published private(set) var skipMarker: PlexMarker?
    /// Seconds left before the next episode starts; non-nil while the Up Next card shows.
    @Published private(set) var upNextSeconds: Int?
    /// Moving to another episode.
    @Published private(set) var switching = false
    @Published private(set) var subtitleDelayMs = 0
    /// Name of the speaker/headphones/car the sound is going to (e.g. "Silverado").
    @Published private(set) var audioOutputName = ""
    /// Short message shown on the video for a few seconds.
    @Published private(set) var toast: String?

    static let upNextCountdown = 10
    private var markers: [PlexMarker] = []
    private var upNextCancelled = false
    private var upNextDeadline: Date?
    private var skippedMarkers = Set<Double>()
    private var pendingSubtitles: [URL] = []
    private var routeObserver: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?

    /// The view VLC draws into. It moves between the phone and car screens.
    let videoView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        return v
    }()

    private var vlc: VLCMediaPlayer?
    private var proxy: StreamProxy?
    private var mediaURL: URL?
    private var reportTimer: Timer?
    private var watchdog: Timer?
    private let location = CLLocationManager()

    /// What the user wants (playing vs paused).
    private var wantsPlay = false
    private var lastProgress = Date()
    private var lastTimeValue: Double = -1
    private var hasPlayedSinceStart = false
    private var restartsWithoutPlaying = 0
    private var restartPending = false

    private var state: AppState { AppState.shared }
    private var client: PlexClient { AppState.shared.client }

    private override init() {
        super.init()
        location.delegate = self
        setupRemoteCommands()
        audioOutputName = Self.currentOutputName()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioRouteChanged() }
        }
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
        // Lists usually include the file details; only look them up if missing.
        if target.firstPart?.key == nil || target.firstPart?.size == nil,
           let fresh = try? await client.metadata(target.ratingKey.value) {
            target = fresh
        }

        await stop(reportOnly: true)

        guard let remote = client.directURL(for: target) else {
            errorMessage = "Couldn't find the file for this video."
            return
        }

        current = target
        nextItem = nil
        markers = []
        skipMarker = nil
        upNextSeconds = nil
        upNextDeadline = nil
        upNextCancelled = false
        skippedMarkers = []
        pendingSubtitles = []
        subtitleDelayMs = 0
        duration = Double(target.duration ?? 0) / 1000
        var resume = fromStart ? 0 : Double(target.viewOffset ?? 0) / 1000
        if duration > 0, resume > duration - 120 { resume = 0 }  // nearly done: start over
        currentTime = resume
        hasPlayedSinceStart = false
        restartsWithoutPlaying = 0
        isActive = true
        isBuffering = true

        // Route through the on-phone cache when we know the file size (almost always).
        var url = remote
        if let size = target.firstPart?.size, size > 0, duration > 0 {
            let p = StreamProxy(remote: remote, size: size, duration: duration,
                                aheadSeconds: Double(state.bufferMinutes * 60),
                                container: target.container)
            if let local = try? await p.start() {
                proxy = p
                url = local
            } else {
                DispatchQueue.global(qos: .utility).async { p.stop() }  // fall back to streaming straight from Plex
            }
        }
        mediaURL = url

        wantsPlay = !heldForMotion
        startVLC(at: resume)
        startTimers()
        updateNowPlaying()
        fetchExtras(for: target)
    }

    /// Stops playback and saves the position to Plex.
    func stop(reportOnly: Bool = false) async {
        if !reportOnly { showPlayerUI = false; resetZoom() }
        guard isActive, let item = current else {
            isActive = false
            return
        }
        let t = currentTime
        reportTimer?.invalidate()
        reportTimer = nil
        watchdog?.invalidate()
        watchdog = nil

        vlc?.delegate = nil
        vlc?.stop()
        vlc = nil
        let oldProxy = proxy
        proxy = nil
        mediaURL = nil
        DispatchQueue.global(qos: .utility).async { oldProxy?.stop() }

        isActive = false
        current = nil
        nextItem = nil
        skipMarker = nil
        upNextSeconds = nil
        upNextDeadline = nil
        isPlaying = false
        isBuffering = false
        offline = false
        waitingForSignal = false
        bufferedAhead = 0
        wantsPlay = false
        restartPending = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let durMs = Int(duration * 1000)
        let watched = duration > 0 && t / duration > 0.9
        let c = client
        let refresh = !reportOnly
        // Report in the background so the next video doesn't wait on these calls.
        Task {
            await c.reportTimeline(item: item, state: "stopped", timeMs: Int(t * 1000), durationMs: durMs)
            if watched { await c.markWatched(item.ratingKey.value) }
            if refresh { await AppState.shared.refreshContinueWatching() }
        }
    }

    // MARK: - Mini player

    /// Pause and shrink to the mini player along the bottom of the app.
    // MARK: - Zoom (full-screen player on the phone only)

    @Published private(set) var zoomScale: CGFloat = 1
    private var zoomPan: CGSize = .zero
    private var zoomStep = 0

    private func applyZoom() {
        let on = showPlayerUI && !carScreenActive
        videoView.transform = on
            ? CGAffineTransform(translationX: zoomPan.width, y: zoomPan.height).scaledBy(x: zoomScale, y: zoomScale)
            : .identity
    }

    /// How much to enlarge the fitted picture so it fills the screen with no black bars.
    private func fillScale(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        var aspect: CGFloat = 16.0 / 9.0
        if let v = vlc?.videoSize, v.width > 0, v.height > 0 { aspect = v.width / v.height }
        let fitW = min(size.width, size.height * aspect)
        let fitH = fitW / aspect
        return max(size.width / fitW, size.height / fitH)
    }

    /// Double tap in step mode: 1 of 3, 2 of 3, fill the screen, then back to normal.
    func zoomStepTap(in size: CGSize) {
        let fill = fillScale(size)
        let levels: [CGFloat] = fill > 1.02 ? [1, 1 + (fill - 1) / 3, 1 + 2 * (fill - 1) / 3, fill] : [1, 1.1, 1.2, 1.33]
        zoomStep = (zoomStep + 1) % 4
        zoomScale = levels[zoomStep]
        zoomPan = .zero
        applyZoom()
        showToast(zoomStep == 0 ? "Original size" : zoomStep == 3 ? "Zoom 3 of 3 · fill screen" : "Zoom \(zoomStep) of 3")
    }

    /// Pinch mode: scale by `factor` and move by `dx`,`dy`, kept inside the screen.
    func pinch(factor: CGFloat, dx: CGFloat, dy: CGFloat, in size: CGSize) {
        let z = min(max(zoomScale * factor, 1), 4)
        zoomScale = z
        let maxX = (z - 1) * size.width / 2
        let maxY = (z - 1) * size.height / 2
        zoomPan = CGSize(width: min(max(zoomPan.width + dx, -maxX), maxX),
                         height: min(max(zoomPan.height + dy, -maxY), maxY))
        applyZoom()
    }

    func resetZoom(announce: Bool = false) {
        let was = zoomScale != 1
        zoomStep = 0
        zoomScale = 1
        zoomPan = .zero
        applyZoom()
        if announce && was { showToast("Original size") }
    }

    func minimize() {
        if wantsPlay { togglePlayPause() }
        showPlayerUI = false
    }

    /// Back to the full-screen player from the mini player.
    func expand() {
        guard isActive else { return }
        showPlayerUI = true
    }

    // MARK: - Controls

    func togglePlayPause() {
        guard let vlc else { return }
        if wantsPlay {
            wantsPlay = false
            vlc.pause()
        } else {
            if heldForMotion { return }
            wantsPlay = true
            vlc.play()
        }
        isPlaying = wantsPlay
        lastProgress = Date()
        reportNow()
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        guard let vlc else { return }
        let clamped = max(0, duration > 0 ? min(seconds, duration - 2) : seconds)
        vlc.time = VLCTime(int: Int32(clamped * 1000))
        currentTime = clamped
        lastProgress = Date()
        reportNow()
    }

    // MARK: - Audio & subtitle tracks

    var audioTracks: [Track] { tracks(indexes: vlc?.audioTrackIndexes, names: vlc?.audioTrackNames) }
    var subtitleTracks: [Track] { tracks(indexes: vlc?.videoSubTitlesIndexes, names: vlc?.videoSubTitlesNames) }
    var currentAudioTrack: Int32 { vlc?.currentAudioTrackIndex ?? -1 }
    var currentSubtitleTrack: Int32 { vlc?.currentVideoSubTitleIndex ?? -1 }

    func selectAudioTrack(_ id: Int32) {
        vlc?.currentAudioTrackIndex = id
        objectWillChange.send()
    }

    func selectSubtitleTrack(_ id: Int32) {
        vlc?.currentVideoSubTitleIndex = id
        objectWillChange.send()
    }

    private func tracks(indexes: [Any]?, names: [Any]?) -> [Track] {
        guard let indexes, let names else { return [] }
        return zip(indexes, names).compactMap { idx, name in
            guard let n = idx as? NSNumber else { return nil }
            return Track(id: n.int32Value, name: (name as? String) ?? "Track \(n.intValue)")
        }
    }

    // MARK: - VLC

    private func startVLC(at seconds: Double) {
        guard let url = mediaURL else { return }
        let player = VLCMediaPlayer()
        player.delegate = self
        player.drawable = videoView

        let media = VLCMedia(url: url)
        // The cache server is local, so VLC itself only needs a short buffer; starts fast.
        media.addOption(":network-caching=1200")
        if seconds > 1 { media.addOption(":start-time=\(Int(seconds))") }
        player.media = media
        vlc = player

        lastProgress = Date()
        lastTimeValue = -1
        player.play()
        if !wantsPlay {
            // VLC needs play() to open the file; pause right after if we're held.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.wantsPlay else { return }
                self.vlc?.pause()
            }
        }
    }

    /// Something went wrong inside VLC. Reopen at the same spot (the cache still has the data).
    private func restartVLC() {
        guard isActive, !restartPending else { return }
        if !hasPlayedSinceStart {
            restartsWithoutPlaying += 1
            if restartsWithoutPlaying > 3 {
                errorMessage = "This video couldn't be played."
                return
            }
        }
        restartPending = true
        let at = currentTime
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isActive, self.restartPending else { return }
            self.restartPending = false
            self.vlc?.delegate = nil
            self.vlc?.stop()
            self.vlc = nil
            self.startVLC(at: at)
        }
    }

    fileprivate func vlcStateChanged() {
        guard let p = vlc else { return }
        switch p.state {
        case .playing:
            applyDelays(to: p)   // also after reconnecting from a dead zone (new player)
            hasPlayedSinceStart = true
            restartsWithoutPlaying = 0
            addPendingSubtitles()
            if !wantsPlay || heldForMotion { p.pause() }
            if duration <= 0, let len = p.media?.length.intValue, len > 0 { duration = Double(len) / 1000 }
        case .ended:
            if duration > 0 && currentTime >= duration - 20 {
                Task { await finished() }
            } else {
                restartVLC()  // ended early: data hiccup, not the real end
            }
        case .error:
            restartVLC()
        default:
            break
        }
        isPlaying = wantsPlay
        updateNowPlaying()
    }

    fileprivate func vlcTimeChanged() {
        guard let p = vlc, let ms = p.time.value?.doubleValue else { return }
        let t = ms / 1000
        if t > 0 {
            if abs(t - lastTimeValue) > 0.01 { lastProgress = Date() }
            lastTimeValue = t
            currentTime = t
        }
    }

    // MARK: - Timers

    private func startTimers() {
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reportNow() }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    /// Every second: buffer readout, buffering spinner, signal status.
    private func watchdogTick() {
        guard isActive else { return }
        if let snap = proxy?.snapshot() {
            bufferedAhead = Double(snap.bufferedBytes) / snap.bytesPerSecond
            offline = snap.offline
        }
        let stalled = wantsPlay && !heldForMotion && Date().timeIntervalSince(lastProgress) > 1.5
        isBuffering = stalled
        waitingForSignal = stalled && offline
        // VLC sometimes gives up after a long dead zone. If it's been stuck a long time
        // and data is available again, reopen it at the same spot.
        if stalled && !offline && hasPlayedSinceStart && bufferedAhead > 5
            && Date().timeIntervalSince(lastProgress) > 15 {
            restartVLC()
        }
        updateMarkers()
    }

    private func reportNow() {
        guard let item = current, isActive, !offline else { updateNowPlaying(); return }
        let st = wantsPlay ? "playing" : "paused"
        let t = Int(currentTime * 1000)
        let d = Int(duration * 1000)
        Task { await client.reportTimeline(item: item, state: st, timeMs: t, durationMs: d) }
        updateNowPlaying()
    }

    /// End of video: mark watched and roll into the next episode (unless Up Next was cancelled).
    private func finished() async {
        guard let item = current else { return }
        currentTime = duration
        var next: PlexItem? = nil
        if !upNextCancelled {
            if let n = nextItem { next = n } else { next = await nextEpisode(after: item) }
        }
        await stop(reportOnly: next != nil)
        if let next {
            await client.markWatched(item.ratingKey.value)
            await play(next, fromStart: true)
        }
    }

    // MARK: - Previous / next episode

    /// More than 5 seconds in: back to the start. Within the first 5 seconds: the previous episode.
    func previous() {
        guard let item = current, !switching else { return }
        if currentTime > 5 || item.type != "episode" {
            seek(to: 0)
            if !wantsPlay { togglePlayPause() }
            return
        }
        switching = true
        Task {
            let prev = try? await client.episode(adjacentTo: item, offset: -1)
            if let prev {
                await switchTo(prev, markWatched: false)
            } else {
                switching = false
                seek(to: 0)
                showToast("This is the first episode")
            }
        }
    }

    func playNext() {
        guard let next = nextItem, !switching else { return }
        Task { await switchTo(next, markWatched: false) }
    }

    private func switchTo(_ other: PlexItem, markWatched: Bool) async {
        let leaving = current
        switching = true
        upNextSeconds = nil
        upNextDeadline = nil
        if markWatched, let leaving {
            let c = client
            Task { await c.markWatched(leaving.ratingKey.value) }
        }
        await play(other, fromStart: true)
        switching = false
    }

    // MARK: - Skip intro / credits, Up Next

    private func fetchExtras(for item: PlexItem) {
        let c = client
        Task {
            let full = try? await c.details(item.ratingKey.value)
            let next = item.type == "episode" ? (try? await c.episode(adjacentTo: item, offset: 1)) : nil
            guard let current, current.ratingKey == item.ratingKey else { return }
            markers = (full?.Marker ?? []).filter { $0.isIntro || $0.isCredits }
            nextItem = next
            let streams = full?.firstPart?.Stream ?? []
            pendingSubtitles = streams.filter { $0.isExternalSubtitle }.compactMap { s in
                s.key.flatMap { c.streamURL($0) }
            }
            if hasPlayedSinceStart { addPendingSubtitles() }
        }
    }

    private func addPendingSubtitles() {
        guard let vlc, !pendingSubtitles.isEmpty else { return }
        let subs = pendingSubtitles
        pendingSubtitles = []
        for url in subs {
            _ = vlc.addPlaybackSlave(url, type: .subtitle, enforce: false)
        }
        objectWillChange.send()
    }

    private func updateMarkers() {
        guard isActive, !switching else { skipMarker = nil; return }
        let t = currentTime
        let credits = markers.first { $0.isCredits && $0.end >= duration - 15 }
        let startAt: Double? = credits?.start ?? (duration > 180 ? duration - 30 : nil)
        if upNextCancelled, let s = startAt, t < s { upNextCancelled = false }  // rewound out of the credits

        if let next = nextItem, !upNextCancelled, let s = startAt, t >= s, duration - t > 1 {
            if upNextDeadline == nil {
                upNextDeadline = Date().addingTimeInterval(Double(Self.upNextCountdown))
            } else if (!wantsPlay || isBuffering), let left = upNextSeconds {
                upNextDeadline = Date().addingTimeInterval(Double(left))  // hold the count while paused
            }
            let left = max(0, Int(ceil(upNextDeadline?.timeIntervalSinceNow ?? 0)))
            upNextSeconds = left
            skipMarker = nil
            if left <= 0 {
                Task { await switchTo(next, markWatched: true) }
            }
            return
        }
        upNextSeconds = nil
        upNextDeadline = nil

        let active = markers.first { t >= $0.start - 0.5 && t < $0.end - 1 }
        if let m = active, !skippedMarkers.contains(m.start) {
            skipMarker = m
        } else {
            skipMarker = nil
        }
    }

    func skipCurrentMarker() {
        guard let m = skipMarker else { return }
        skippedMarkers.insert(m.start)
        skipMarker = nil
        if m.isCredits && m.end >= duration - 15 {
            if let next = nextItem {
                Task { await switchTo(next, markWatched: true) }
            } else {
                seek(to: duration - 2)
            }
        } else {
            seek(to: m.end)
        }
    }

    func playUpNextNow() {
        guard let next = nextItem else { return }
        Task { await switchTo(next, markWatched: true) }
    }

    func cancelUpNext() {
        upNextCancelled = true
        upNextSeconds = nil
        upNextDeadline = nil
    }

    // MARK: - Subtitle timing & audio delay (remembered per audio output)

    func setSubtitleDelay(_ ms: Int) {
        subtitleDelayMs = ms
        vlc?.currentVideoSubTitleDelay = ms * 1000   // VLC uses microseconds
    }

    var audioDelayMs: Int { state.audioDelays[audioOutputName] ?? 0 }

    func setAudioDelay(_ ms: Int) {
        var d = state.audioDelays
        d[audioOutputName] = ms == 0 ? nil : ms
        state.audioDelays = d
        vlc?.currentAudioPlaybackDelay = ms * 1000
        objectWillChange.send()
    }

    private func applyDelays(to p: VLCMediaPlayer) {
        p.currentAudioPlaybackDelay = audioDelayMs * 1000
        p.currentVideoSubTitleDelay = subtitleDelayMs * 1000
    }

    private func audioRouteChanged() {
        let name = Self.currentOutputName()
        guard name != audioOutputName else { return }
        audioOutputName = name
        vlc?.currentAudioPlaybackDelay = audioDelayMs * 1000
        if isActive {
            let ms = audioDelayMs
            showToast("Audio: \(name)" + (ms != 0 ? "  ·  delay \(ms > 0 ? "+" : "")\(ms) ms" : ""))
        }
    }

    static func currentOutputName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "iPhone"
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
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
            Task { @MainActor in if self?.wantsPlay == false { self?.togglePlayPause() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.wantsPlay == true { self?.togglePlayPause() } }
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
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
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
            MPNowPlayingInfoPropertyPlaybackRate: wantsPlay ? 1.0 : 0.0,
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
            wantsPlay = false
            isPlaying = false
            vlc?.pause()
        } else if !moving && heldForMotion {
            heldForMotion = false
        }
    }
}

extension PlaybackManager: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in self.vlcStateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.vlcTimeChanged() }
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
