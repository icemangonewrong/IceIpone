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
    private weak var carVideo: CarVideoViewController?
    private var cancellables = Set<AnyCancellable>()

    private var app: AppState { AppState.shared }
    private var playback: PlaybackManager { PlaybackManager.shared }

    // MARK: - Connect / disconnect

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        self.interfaceController = interfaceController
        self.carWindow = window

        let video = CarVideoViewController()
        window.rootViewController = video
        carVideo = video
        playback.carScreenActive = true

        let map = CPMapTemplate()
        map.automaticallyHidesNavigationBar = false
        map.leadingNavigationBarButtons = [
            CPBarButton(title: "Browse") { [weak self] _ in self?.showBrowse() },
        ]
        map.trailingNavigationBarButtons = [
            CPBarButton(title: "Stop") { [weak self] _ in
                Task { await self?.playback.stop() }
            },
        ]

        let back = CPMapButton { [weak self] _ in self?.playback.skip(-10) }
        back.image = UIImage(systemName: "gobackward.10")
        let playPause = CPMapButton { [weak self] _ in self?.playback.togglePlayPause() }
        playPause.image = UIImage(systemName: "playpause.fill")
        let forward = CPMapButton { [weak self] _ in self?.playback.skip(10) }
        forward.image = UIImage(systemName: "goforward.10")
        let next = CPMapButton { [weak self] _ in self?.playback.playNext() }
        next.image = UIImage(systemName: "forward.end.fill")
        map.mapButtons = [back, playPause, forward, next]
        playPauseButton = playPause

        map.mapDelegate = self
        mapTemplate = map
        interfaceController.setRootTemplate(map, animated: false, completion: nil)

        playback.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                self?.playPauseButton?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
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

            let cw = Array(app.continueWatching.prefix(12)).map { makeItemRow($0) }
            if !cw.isEmpty {
                sections.append(CPListSection(items: cw, header: "Continue Watching", sectionIndexTitle: nil))
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

    /// One row in a CarPlay list. Playable items start playing; shows/seasons drill down.
    private func makeItemRow(_ item: PlexItem) -> CPListItem {
        let title = item.type == "episode" ? (item.title ?? "") : item.displayTitle
        var detail: String? = item.type == "episode" ? "\(item.displayTitle) · \(item.displaySubtitle ?? "")" : item.displaySubtitle
        if let p = item.progress { detail = (detail.map { $0 + " · " } ?? "") + "\(Int(p * 100))% watched" }

        let row = CPListItem(text: title, detailText: detail)
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
        if let url = app.client.imageURL(item.posterPath, width: 120, height: 180) {
            Task.detached {
                if let result = try? await URLSession.shared.dataCompat(from: url),
                   let img = UIImage(data: result.0) {
                    await MainActor.run { row.setImage(img) }
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

// TOUCH TEST: CarPlay reports drags on the map area through these callbacks.
extension CarPlaySceneDelegate: CPMapTemplateDelegate {
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        carVideo?.probe.record("CarPlay drag started")
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        carVideo?.probe.record("CarPlay drag \(Int(translation.x)),\(Int(translation.y))", countAs: .drag)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        carVideo?.probe.record("CarPlay drag ended")
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        carVideo?.probe.record("CarPlay pan button \(direction.rawValue)", countAs: .drag)
    }
}

// MARK: - Touch test overlay

/// Shows whether the car screen passes touches to Ice: a counter panel, a dot where
/// each touch lands, and a button to tap. (Test build only.)
final class TouchProbeView: UIView {
    enum Kind { case touch, tap, drag, button }
    private let panel = UILabel()
    private let button = UIButton(type: .system)
    private var counts: [Kind: Int] = [.touch: 0, .tap: 0, .drag: 0, .button: 0]
    private var lastEvent = "nothing yet"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        panel.numberOfLines = 0
        panel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        panel.textColor = .white
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        panel.layer.cornerRadius = 8
        panel.layer.masksToBounds = true
        panel.isUserInteractionEnabled = false
        addSubview(panel)

        button.setTitle("  Tap me  ", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        button.backgroundColor = .systemOrange
        button.setTitleColor(.black, for: .normal)
        button.layer.cornerRadius = 10
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        addSubview(button)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        addGestureRecognizer(pan)
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = panel.sizeThatFits(CGSize(width: 330, height: 400))
        panel.frame = CGRect(x: safeAreaInsets.left + 12, y: safeAreaInsets.top + 12,
                             width: size.width + 16, height: size.height + 12)
        button.sizeToFit()
        button.frame.size = CGSize(width: button.frame.width + 20, height: 46)
        button.frame.origin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY + 12)
    }

    func record(_ event: String, countAs kind: Kind? = nil) {
        if let kind { counts[kind, default: 0] += 1 }
        lastEvent = event
        render()
    }

    private func render() {
        panel.text = """
         TOUCH TEST
         Touches:  \(counts[.touch] ?? 0)
         Taps:     \(counts[.tap] ?? 0)
         Drags:    \(counts[.drag] ?? 0)
         Button:   \(counts[.button] ?? 0)
         Last: \(lastEvent)
        """
        setNeedsLayout()
    }

    private func dot(at p: CGPoint, color: UIColor) {
        let d = UIView(frame: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
        d.backgroundColor = color.withAlphaComponent(0.8)
        d.layer.cornerRadius = 18
        d.isUserInteractionEnabled = false
        addSubview(d)
        UIView.animate(withDuration: 1.2, animations: { d.alpha = 0; d.transform = CGAffineTransform(scaleX: 2, y: 2) }) { _ in
            d.removeFromSuperview()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for t in touches {
            let p = t.location(in: self)
            dot(at: p, color: .systemGreen)
            record("touch at \(Int(p.x)),\(Int(p.y))", countAs: .touch)
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        dot(at: p, color: .systemBlue)
        record("tap at \(Int(p.x)),\(Int(p.y))", countAs: .tap)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        if g.state == .changed || g.state == .began {
            let p = g.location(in: self)
            dot(at: p, color: .systemPurple)
            record("drag at \(Int(p.x)),\(Int(p.y))", countAs: .drag)
        }
    }

    @objc private func buttonTapped() {
        record("button pressed", countAs: .button)
        button.backgroundColor = button.backgroundColor == .systemOrange ? .systemGreen : .systemOrange
    }
}

// MARK: - The video on the car screen

final class CarVideoViewController: UIViewController {
    let probe = TouchProbeView()
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

        // TOUCH TEST overlay on top of everything
        probe.frame = view.bounds
        probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(probe)
        view.isUserInteractionEnabled = true

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
