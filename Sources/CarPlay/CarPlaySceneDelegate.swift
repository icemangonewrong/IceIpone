import UIKit
import CarPlay
import AVFoundation
import Combine

/// CarPlay screen. Only appears in the car when the app is installed with a CarPlay
/// entitlement (the jailbreak/TrollStore build). With a normal sideload it never runs.
///
/// It registers as a navigation-style app, which is the only kind that gets a raw
/// drawing window on the car display. The video is drawn in that window, and
/// browsing uses CarPlay's built-in list screens.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var playPauseButton: CPMapButton?
    private var playPauseBarButton: CPBarButton?
    private var idleBar: ([CPBarButton], [CPBarButton]) = ([], [])
    private var playingBar: ([CPBarButton], [CPBarButton]) = ([], [])

    static func symbol(_ name: String) -> UIImage {
        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        return (UIImage(systemName: name, withConfiguration: cfg) ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }
    private var cancellables = Set<AnyCancellable>()

    private var app: AppState { AppState.shared }
    private var playback: PlaybackManager { PlaybackManager.shared }

    // MARK: - Connect / disconnect

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        self.carWindow = window

        window.rootViewController = CarVideoViewController()
        playback.carScreenActive = true

        let map = CPMapTemplate()
        // Top bar: always up when nothing is playing or it's paused; hides itself while playing
        // and comes back when the screen is tapped (CarPlay handles that).
        map.automaticallyHidesNavigationBar = false
        let browse = CPBarButton(title: "Browse") { [weak self] _ in self?.showBrowse() }
        let back10 = CPBarButton(image: Self.symbol("gobackward.10")) { [weak self] _ in self?.playback.skip(-10) }
        let playPauseBar = CPBarButton(image: Self.symbol("play.fill")) { [weak self] _ in self?.playback.togglePlayPause() }
        let fwd10 = CPBarButton(image: Self.symbol("goforward.10")) { [weak self] _ in self?.playback.skip(10) }
        idleBar = ([browse], [])
        playingBar = ([browse, back10], [playPauseBar, fwd10])
        playPauseBarButton = playPauseBar
        map.leadingNavigationBarButtons = [browse]
        map.trailingNavigationBarButtons = []

        let back = CPMapButton { [weak self] _ in self?.playback.skip(-10) }
        back.image = Self.symbol("gobackward.10")
        let playPause = CPMapButton { [weak self] _ in self?.playback.togglePlayPause() }
        playPause.image = Self.symbol("playpause.fill")
        let forward = CPMapButton { [weak self] _ in self?.playback.skip(10) }
        forward.image = Self.symbol("goforward.10")
        let next = CPMapButton { [weak self] _ in self?.playback.playNext() }
        next.image = Self.symbol("forward.end.fill")
        map.mapButtons = [back, playPause, forward, next]
        // Keep the playback buttons on screen (the car screen doesn't pass touches to the video itself).
        map.hidesButtonsWithNavigationBar = false
        playPauseButton = playPause

        mapTemplate = map
        interfaceController.setRootTemplate(map, animated: false, completion: nil)

        playback.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                let img = Self.symbol(playing ? "pause.fill" : "play.fill")
                self?.playPauseButton?.image = img
                self?.playPauseBarButton?.image = img
                // Get the bar out of the way while watching; tap the screen to bring it back.
                self?.mapTemplate?.automaticallyHidesNavigationBar = playing
            }
            .store(in: &cancellables)

        playback.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self, let map = self.mapTemplate else { return }
                let bar = active ? self.playingBar : self.idleBar
                map.leadingNavigationBarButtons = bar.0
                map.trailingNavigationBarButtons = bar.1
                if !active { map.automaticallyHidesNavigationBar = false }
            }
            .store(in: &cancellables)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        cancellables.removeAll()
        playback.carScreenActive = false
        // Leave it playing on the phone? Safer to pause when the car disconnects.
        if playback.isPlaying { playback.togglePlayPause() }
        self.interfaceController = nil
        self.carWindow = nil
        self.mapTemplate = nil
    }

    // MARK: - Browsing

    private func showBrowse() {
        Task {
            if app.sections.isEmpty { await app.refreshHome() }
            else { await app.refreshContinueWatching() }

            var sections: [CPListSection] = []

            if playback.isActive, let cur = playback.current {
                var rows: [CPListItem] = []
                if let next = playback.nextItem {
                    let r = CPListItem(text: "Play next episode", detailText: Self.subtitle(for: next),
                                       image: Self.symbol("forward.end.fill"))
                    r.handler = { [weak self] _, done in
                        self?.playback.playNext()
                        self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                        done()
                    }
                    rows.append(r)
                }
                let stop = CPListItem(text: "Stop", detailText: "Saves your spot in \(Self.title(for: cur))",
                                      image: Self.symbol("stop.fill"))
                stop.handler = { [weak self] _, done in
                    Task { await self?.playback.stop() }
                    self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                    done()
                }
                rows.append(stop)
                sections.append(CPListSection(items: rows, header: "Now Playing", sectionIndexTitle: nil))
            }

            let cwItems = Array(app.continueWatching.prefix(12))
            if !cwItems.isEmpty {
                let posters = makePosterRow(cwItems)
                let cw = cwItems.map { makeItemRow($0) }
                sections.append(CPListSection(items: [posters] + cw, header: "Continue Watching", sectionIndexTitle: nil))
            }

            let libs: [CPListItem] = app.visibleSections.map { section in
                let row = CPListItem(text: section.title, detailText: nil,
                                     image: UIImage(systemName: section.type == "show" ? "tv" : "film"))
                row.accessoryType = .disclosureIndicator
                row.handler = { [weak self] _, done in
                    self?.showLibrary(section)
                    done()
                }
                return row
            }
            if !libs.isEmpty {
                sections.append(CPListSection(items: libs, header: "Libraries", sectionIndexTitle: nil))
            }
            if sections.isEmpty {
                let empty = CPListItem(text: app.server == nil ? "Sign in on your phone first" : "Nothing here yet",
                                       detailText: nil)
                sections.append(CPListSection(items: [empty]))
            }

            let list = CPListTemplate(title: "Ice", sections: sections)
            interfaceController?.pushTemplate(list, animated: true, completion: nil)
        }
    }

    private func showLibrary(_ section: PlexSection) {
        let client = app.client
        Task {
            async let recentTask = client.recentlyAdded(section: section.key, count: 25)
            async let allTask = client.items(section: section.key, sort: "titleSort",
                                                 unwatchedOnly: false, start: 0,
                                                 size: max(CPListTemplate.maximumItemCount - 25, 25))
            let recent = (try? await recentTask) ?? []
            let all = (try? await allTask)?.items ?? []

            var sections: [CPListSection] = []
            if !recent.isEmpty {
                sections.append(CPListSection(items: recent.map { makeItemRow($0) },
                                              header: "Recently Added", sectionIndexTitle: nil))
            }
            if !all.isEmpty {
                sections.append(CPListSection(items: all.map { makeItemRow($0) },
                                              header: "A–Z", sectionIndexTitle: nil))
            }
            let list = CPListTemplate(title: section.title, sections: sections)
            interfaceController?.pushTemplate(list, animated: true, completion: nil)
        }
    }

    private func showChildren(of item: PlexItem) {
        Task {
            let kids = (try? await app.client.children(of: item.ratingKey.value)) ?? []
            var rows: [CPListItem] = []
            if item.type == "show" {
                let next = CPListItem(text: "Play next episode", detailText: nil,
                                      image: UIImage(systemName: "play.fill"))
                next.handler = { [weak self] _, done in
                    self?.startPlayback(item)
                    done()
                }
                rows.append(next)
            }
            rows.append(contentsOf: kids.map { makeItemRow($0) })
            let list = CPListTemplate(title: item.title ?? "", sections: [CPListSection(items: rows)])
            interfaceController?.pushTemplate(list, animated: true, completion: nil)
        }
    }

    /// Show name for episodes, title for everything else.
    static func title(for item: PlexItem) -> String {
        item.type == "episode" ? (item.grandparentTitle ?? item.displayTitle) : item.displayTitle
    }

    /// "S5 · E10 · Weight" for episodes, the year (or other subtitle) for everything else.
    static func subtitle(for item: PlexItem) -> String? {
        if item.type == "episode" {
            var bits: [String] = []
            if let s = item.parentIndex { bits.append("S\(s)") }
            if let e = item.index { bits.append("E\(e)") }
            if let t = item.title, !t.isEmpty { bits.append(t) }
            return bits.isEmpty ? item.displaySubtitle : bits.joined(separator: " · ")
        }
        return item.displaySubtitle
    }

    /// Continue Watching as one row of posters; tap a poster to resume it.
    private func makePosterRow(_ items: [PlexItem]) -> CPListImageRowItem {
        let shown = Array(items.prefix(CPMaximumNumberOfGridImages))
        let size = CPListImageRowItem.maximumImageSize
        let blank = carImage(UIImage.from(color: UIColor(white: 0.2, alpha: 1), size: size), size: size)
        let row = CPListImageRowItem(text: "Continue Watching", images: shown.map { _ in blank })
        row.listImageRowHandler = { [weak self] _, index, done in
            if index < shown.count { self?.startPlayback(shown[index]) }
            done()
        }
        row.handler = { _, done in done() }
        Task {
            var images = shown.map { _ in blank }
            for (i, item) in shown.enumerated() {
                guard let url = app.client.imageURL(item.posterPath, width: 600, height: 900),
                      let result = try? await URLSession.shared.dataCompat(from: url),
                      let img = UIImage(data: result.0) else { continue }
                images[i] = carImage(img, size: size)
                row.update(images)
            }
        }
        return row
    }

    /// Redraws a picture at exactly the size CarPlay shows it, at the car screen's pixel density,
    /// so CarPlay doesn't scale a small phone image up (which is what made the posters blurry).
    private func carImage(_ img: UIImage, size: CGSize) -> UIImage {
        let traits = interfaceController?.carTraitCollection
        let scale = max(traits?.displayScale ?? 0, 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let out = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // fill the space, cropping the edges evenly
            let s = max(size.width / max(img.size.width, 1), size.height / max(img.size.height, 1))
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }
        guard let traits else { return out }
        let asset = UIImageAsset()
        asset.register(out, with: traits)
        return asset.image(with: traits)
    }

    /// One row in a CarPlay list. Playable items start playing; shows/seasons drill down.
    private func makeItemRow(_ item: PlexItem) -> CPListItem {
        let row = CPListItem(text: Self.title(for: item), detailText: Self.subtitle(for: item))
        if let p = item.progress {
            row.playbackProgress = CGFloat(p)
        }
        if item.isWatched { row.accessoryType = .none }
        if !item.isPlayable { row.accessoryType = .disclosureIndicator }

        row.handler = { [weak self] _, done in
            if item.isPlayable { self?.startPlayback(item) }
            else { self?.showChildren(of: item) }
            done()
        }

        // Load the poster in the background.
        if let url = app.client.imageURL(item.posterPath, width: 240, height: 360) {
            Task {
                if let result = try? await URLSession.shared.dataCompat(from: url),
                   let img = UIImage(data: result.0) {
                    row.setImage(self.carImage(img, size: CPListItem.maximumImageSize))
                }
            }
        }
        return row
    }

    private func startPlayback(_ item: PlexItem) {
        Task {
            await playback.play(item)
            interfaceController?.popToRootTemplate(animated: true, completion: nil)
        }
    }
}

extension UIImage {
    static func from(color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - The video on the car screen

final class CarVideoViewController: UIViewController {
    private let idleLabel = UILabel()
    private let statusLabel = UILabel()
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Take over the shared video view from the phone.
        let video = PlaybackManager.shared.videoView
        video.removeFromSuperview()
        video.frame = view.bounds
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(video)

        idleLabel.text = "Ice\nTap Browse to pick something"
        idleLabel.numberOfLines = 0
        idleLabel.textAlignment = .center
        idleLabel.textColor = .lightGray
        idleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        statusLabel.textAlignment = .center
        statusLabel.textColor = .systemYellow
        statusLabel.font = .systemFont(ofSize: 20, weight: .bold)
        statusLabel.numberOfLines = 0

        for l in [idleLabel, statusLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                l.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            ])
        }
        idleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16).isActive = true

        let pb = PlaybackManager.shared
        pb.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in self?.idleLabel.isHidden = active }
            .store(in: &cancellables)

        pb.$heldForMotion.combineLatest(pb.$waitingForSignal, pb.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] held, waiting, error in
                if held { self?.statusLabel.text = "Paused while moving" }
                else if waiting { self?.statusLabel.text = "No signal — will continue when it's back" }
                else { self?.statusLabel.text = error }
            }
            .store(in: &cancellables)
    }
}
