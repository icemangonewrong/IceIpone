import SwiftUI
import UIKit

/// Full-screen player on the phone. When video is on the car screen, shows remote controls instead.
struct PlayerScreen: View {
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if playback.carScreenActive {
                CarRemoteView()
                    .overlayCompat(alignment: .topLeading) { CloseButton(minimizes: false).padding() }
            } else if playback.isActive {
                PlayerView()
            } else if let err = playback.errorMessage {
                ErrorPanel(message: err)
            } else {
                OrangeSpinner(size: 56)
                CloseButton(minimizes: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(playback.isActive && !playback.carScreenActive)
    }
}

// MARK: - Video + controls

private struct PlayerView: View {
    @EnvironmentObject var playback: PlaybackManager
    @EnvironmentObject var app: AppState

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showAudioDelay = false
    @State private var showSubtitleTiming = false

    private let barHeight: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 640
            ZStack(alignment: .bottom) {
                VideoHost()
                    .ignoresSafeArea()

                // Tap the picture: pause/play if that's turned on in Settings, otherwise show/hide the bar.
                // Double tap: zoom in 3 steps, 4th back to normal. Pinch: zoom to any size, drag to move.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { playback.zoomStepTap(in: geo.size) }
                    .onTapGesture { tapped() }
                    .simultaneousGesture(pinchGesture(geo.size))

                Group {
                    if playback.waitingForSignal {
                        VStack(spacing: 14) {
                            OrangeSpinner(size: 56)
                            Text("No signal — will pick up where it left off")
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .bg(.black.opacity(0.6), Capsule())
                        }
                    } else if (playback.isBuffering || playback.switching) && !scrubbing {
                        OrangeSpinner(size: 56)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

                VStack(spacing: 8) {
                    if playback.offline && !playback.waitingForSignal {
                        Label("No signal · playing from \(timeString(playback.bufferedAhead)) saved",
                              systemImage: "wifi.slash")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .bg(.black.opacity(0.65), Capsule())
                    }
                    if let toast = playback.toast {
                        Text(toast)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .bg(.black.opacity(0.75), Capsule())
                    }
                }
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

                // Skip Intro / Up Next float above the bar and stay up even when the bar hides.
                VStack(alignment: .trailing) {
                    if let secs = playback.upNextSeconds, let next = playback.nextItem {
                        UpNextCard(next: next, seconds: secs)
                    } else if let m = playback.skipMarker {
                        Button {
                            playback.skipCurrentMarker()
                        } label: {
                            Text(m.isIntro ? "Skip Intro" : "Skip Credits")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 20).padding(.vertical, 11)
                                .bg(.black.opacity(0.75), RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.85), lineWidth: 1.5))
                        }
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, controlsVisible ? (compact ? 150 : barHeight) + 16 : 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                if controlsVisible {
                    CloseButton()
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                    bar(compact: compact)
                        .transition(.opacity)
                }

                if let err = playback.errorMessage {
                    ErrorPanel(message: err)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .foregroundColor(.white)
        .onAppear { scheduleHide() }
        .onChange(of: playback.isPlaying) { _ in scheduleHide() }
        .sheet(isPresented: $showAudioDelay, onDismiss: scheduleHide) {
            AdjustSheet(title: "Audio delay",
                        note: "For \(playback.audioOutputName). Saved for this device and used automatically whenever it's connected.",
                        value: playback.audioDelayMs, step: 50,
                        minusLabel: "Sound earlier", plusLabel: "Sound later",
                        describe: { $0 < 0 ? "Sound plays earlier" : ($0 > 0 ? "Sound plays later" : "No adjustment") },
                        onChange: { playback.setAudioDelay($0) })
                .sheetHeight(330)
        }
        .sheet(isPresented: $showSubtitleTiming, onDismiss: scheduleHide) {
            AdjustSheet(title: "Subtitle timing", note: "For this video.",
                        value: playback.subtitleDelayMs, step: 100,
                        minusLabel: "Earlier", plusLabel: "Later",
                        describe: { $0 < 0 ? "Subtitles show earlier" : ($0 > 0 ? "Subtitles show later" : "No adjustment") },
                        onChange: { playback.setSubtitleDelay($0) })
                .sheetHeight(300)
        }
    }

    // MARK: Bottom bar (layout A1)

    @ViewBuilder
    private func bar(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrubBar(current: playback.currentTime,
                     buffered: playback.bufferedAhead,
                     duration: playback.duration) { time, dragging in
                scrubValue = time
                if dragging {
                    if !scrubbing { scrubbing = true; hideTask?.cancel() }
                } else {
                    playback.seek(to: time)
                    scrubbing = false
                    scheduleHide()
                }
            }
            .frame(height: 22)
            .padding(.horizontal, 12)

            if compact {
                VStack(spacing: 6) {
                    HStack(alignment: .center) {
                        info
                        Spacer(minLength: 8)
                        rightButtons
                    }
                    // X sits halfway between Next and the edge so it isn't hit by accident.
                    HStack(spacing: 0) {
                        Spacer(minLength: 0).frame(maxWidth: .infinity)
                        transport
                        HStack(spacing: 0) { Spacer(minLength: 0); closeButton; Spacer(minLength: 0) }
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            } else {
                // Equal-width halves keep play centered; the X sits halfway between Next and the right buttons.
                HStack(spacing: 0) {
                    HStack(spacing: 0) { info; Spacer(minLength: 12) }
                        .frame(maxWidth: .infinity)
                    transport
                    HStack(spacing: 0) {
                        Spacer(minLength: 8)
                        closeButton
                        Spacer(minLength: 8)
                        rightButtons
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(height: barHeight - 22)
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08).opacity(0.92).ignoresSafeArea(edges: .bottom))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let item = playback.current {
                Text(item.displayTitle).font(.headline).lineLimit(1)
                Text(item.type == "episode" ? (item.displaySubtitle ?? "") : (item.year.map(String.init) ?? ""))
                    .font(.caption).foregroundColor(.white.opacity(0.65)).lineLimit(1)
            }
            let shown = scrubbing ? scrubValue : playback.currentTime
            Text("\(timeString(shown)) / \(timeString(playback.duration))"
                 + (playback.bufferedAhead > 1 ? "  ·  \(timeString(playback.bufferedAhead)) loaded" : ""))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    /// Previous | ⟲10  ▶  10⟳ | Next — previous/next sit apart behind dividers so they're hard to hit by accident.
    private var transport: some View {
        let isEpisode = playback.current?.type == "episode"
        return HStack(spacing: 0) {
            barButton("backward.end.fill", size: 20) { playback.previous() }
            Spacer().frame(width: 20)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1.5, height: 30)
            Spacer().frame(width: 24)
            barButton("gobackward.10", size: 26) { playback.skip(-10) }
            Spacer().frame(width: 16)
            Button {
                playback.togglePlayPause()
                scheduleHide()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 54, height: 54)
                    .bg(.white.opacity(0.15), Circle())
            }
            Spacer().frame(width: 16)
            barButton("goforward.10", size: 26) { playback.skip(10) }
            Spacer().frame(width: 24)
            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1.5, height: 30)
                .opacity(isEpisode ? 1 : 0)
            Spacer().frame(width: 20)
            barButton("forward.end.fill", size: 20) { playback.playNext() }
                .opacity(isEpisode ? (playback.nextItem == nil ? 0.35 : 1) : 0)
                .disabled(!isEpisode || playback.nextItem == nil)
        }
    }

    /// Stop the video (saves the spot) and close the player.
    private var closeButton: some View {
        Button {
            Task { await playback.stop() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 19, weight: .bold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var rightButtons: some View {
        HStack(spacing: 4) {
            TracksMenu(onOpen: { hideTask?.cancel() },
                       onSubtitleTiming: { hideTask?.cancel(); showSubtitleTiming = true })
            Button {
                hideTask?.cancel()
                showAudioDelay = true
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .semibold))
                    .overlayCompat(alignment: .bottomTrailing) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .offset(x: 5, y: 4)
                    }
                    .frame(width: 44, height: 44)
            }
        }
    }

    private func barButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
    }

    @State private var lastMagnification: CGFloat = 1
    @State private var lastDrag: CGSize = .zero

    private func pinchGesture(_ size: CGSize) -> some Gesture {
        MagnificationGesture()
            .simultaneously(with: DragGesture(minimumDistance: 8))
            .onChanged { v in
                var factor: CGFloat = 1
                if let m = v.first {
                    factor = m / lastMagnification
                    lastMagnification = m
                }
                var dx: CGFloat = 0, dy: CGFloat = 0
                if let d = v.second {
                    dx = d.translation.width - lastDrag.width
                    dy = d.translation.height - lastDrag.height
                    lastDrag = d.translation
                }
                playback.pinch(factor: factor, dx: dx, dy: dy, in: size)
            }
            .onEnded { _ in
                lastMagnification = 1
                lastDrag = .zero
            }
    }

    private func tapped() {
        if app.tapToPause {
            playback.togglePlayPause()
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard playback.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && !scrubbing && !showAudioDelay && !showSubtitleTiming {
                withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
            }
        }
    }
}

/// "Up next" countdown card with Play now / Cancel.
private struct UpNextCard: View {
    @EnvironmentObject var playback: PlaybackManager
    let next: PlexItem
    let seconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("UP NEXT · PLAYING IN \(seconds)")
                .font(.caption.weight(.bold))
                .foregroundColor(Color.ice)
            Text(next.title ?? "Next episode").font(.headline).lineLimit(1)
            Text(episodeCode(next)).font(.caption).foregroundColor(.white.opacity(0.65))
            HStack(spacing: 10) {
                Button {
                    playback.playUpNextNow()
                } label: {
                    Text("Play now").font(.subheadline.weight(.bold)).frame(maxWidth: .infinity)
                }
                .prominentButton()
                .iceTint(Color.ice)
                .foregroundColor(.black)
                Button("Cancel") { playback.cancelUpNext() }
                    .borderedButton()
                    .iceTint(.white)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 300)
        .bg(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.95), RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15)))
    }
}

/// − / + adjuster used for audio delay and subtitle timing.
private struct AdjustSheet: View {
    let title: String
    let note: String
    @State var value: Int
    let step: Int
    let minusLabel: String
    let plusLabel: String
    let describe: (Int) -> String
    let onChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.title3.bold())
            Text(note).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            Text(value == 0 ? "0 ms" : "\(value > 0 ? "+" : "")\(value) ms")
                .font(.system(size: 34, weight: .bold).monospacedDigit())
            Text(describe(value)).font(.subheadline).foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button { set(value - step) } label: {
                    Label(minusLabel, systemImage: "chevron.left").frame(maxWidth: .infinity)
                }
                Button { set(value + step) } label: {
                    Label(plusLabel, systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .frame(maxWidth: .infinity)
                }
            }
            .borderedButton()
            .largeControl()
            Button("Reset to 0") { set(0) }
                .borderlessButton()
                .iceTint(Color.ice)
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }

    private func set(_ v: Int) {
        value = max(-5000, min(5000, v))
        onChange(value)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

private struct CloseButton: View {
    @EnvironmentObject var playback: PlaybackManager
    /// true: pause and drop to the mini player. false: stop playback.
    var minimizes = true

    var body: some View {
        Button {
            if minimizes && playback.isActive {
                playback.minimize()
            } else {
                Task { await playback.stop() }
            }
        } label: {
            Image(systemName: minimizes && playback.isActive ? "chevron.down" : "xmark")
                .font(.system(size: 18, weight: .bold))
                .frame(width: 40, height: 40)
                .frosted(Circle())
        }
        .foregroundColor(.white)
    }
}

private struct ErrorPanel: View {
    @EnvironmentObject var playback: PlaybackManager
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
            Button("Close") { Task { await playback.stop() } }
                .prominentButton().iceTint(Color.ice)
        }
        .foregroundColor(.white)
        .padding(24)
        .bg(.black.opacity(0.7), RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

/// Hosts the shared video view that VLC draws into.
struct VideoHost: UIViewRepresentable {
    /// Changing this re-attaches the video here (used by the mini player).
    var attachKey = 0

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        let video = PlaybackManager.shared.videoView
        guard video.superview !== container else { return }
        video.removeFromSuperview()
        video.frame = container.bounds
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(video)
    }
}

/// Audio language and subtitle picker (the "…" button).
private struct TracksMenu: View {
    @EnvironmentObject var playback: PlaybackManager
    let onOpen: () -> Void
    let onSubtitleTiming: () -> Void

    var body: some View {
        Menu {
            let audio = playback.audioTracks
            if !audio.isEmpty {
                Section(header: Text("Audio")) {
                    ForEach(audio) { t in
                        Button {
                            playback.selectAudioTrack(t.id)
                        } label: {
                            if t.id == playback.currentAudioTrack { Label(t.name, systemImage: "checkmark") }
                            else { Text(t.name) }
                        }
                    }
                }
            }
            let subs = playback.subtitleTracks
            if !subs.isEmpty {
                Section(header: Text("Subtitles")) {
                    ForEach(subs) { t in
                        Button {
                            playback.selectSubtitleTrack(t.id)
                        } label: {
                            if t.id == playback.currentSubtitleTrack { Label(t.name, systemImage: "checkmark") }
                            else { Text(t.name) }
                        }
                    }
                }
            }
            if audio.isEmpty && subs.isEmpty {
                Text("No other audio or subtitles")
            }
            Divider()
            Button {
                onSubtitleTiming()
            } label: {
                Label(playback.subtitleDelayMs == 0 ? "Subtitle timing…"
                      : "Subtitle timing… (\(playback.subtitleDelayMs > 0 ? "+" : "")\(playback.subtitleDelayMs) ms)",
                      systemImage: "clock")
            }
        } label: {
            Image(systemName: "text.bubble")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .foregroundColor(.white)
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
    }
}

// MARK: - Car screen remote

/// Phone controls while the video is on the car screen.
struct CarRemoteView: View {
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "car.fill").font(.system(size: 44)).foregroundColor(Color.ice)
            Text("Playing on car screen").font(.headline)
            if let item = playback.current {
                Text(item.type == "episode" ? "\(item.displayTitle) · \(item.displaySubtitle ?? "")" : item.displayTitle)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            if playback.heldForMotion {
                Label("Paused while moving", systemImage: "hand.raised.fill")
                    .foregroundColor(.yellow)
            }

            if playback.duration > 0 {
                Slider(value: Binding(get: { playback.currentTime },
                                      set: { playback.seek(to: $0) }),
                       in: 0...playback.duration)
                    .iceTint(Color.ice)
                HStack {
                    Text(timeString(playback.currentTime))
                    Spacer()
                    Text("−" + timeString(playback.duration - playback.currentTime))
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            }

            HStack(spacing: 44) {
                Button { playback.skip(-10) } label: { Image(systemName: "gobackward.10") }
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                Button { playback.skip(10) } label: { Image(systemName: "goforward.10") }
            }
            .font(.largeTitle)
            .foregroundColor(.white)
        }
        .foregroundColor(.white)
        .padding(32)
    }
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
