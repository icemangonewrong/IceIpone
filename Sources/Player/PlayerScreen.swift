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
                    .overlay(alignment: .topLeading) { CloseButton().padding() }
            } else if playback.isActive {
                PlayerView()
            } else if let err = playback.errorMessage {
                ErrorPanel(message: err)
            } else {
                OrangeSpinner(size: 56)
                CloseButton()
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

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        ZStack {
            VideoHost()
                .ignoresSafeArea()

            // Tap anywhere to show/hide controls.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                    scheduleHide()
                }

            if playback.waitingForSignal {
                VStack(spacing: 14) {
                    OrangeSpinner(size: 56)
                    Text("No signal — will pick up where it left off")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                }
            } else if playback.isBuffering && !scrubbing {
                OrangeSpinner(size: 56)
            }

            if playback.offline && !playback.waitingForSignal {
                Label("No signal · playing from \(timeString(playback.bufferedAhead)) saved",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, controlsVisible ? 64 : 12)
                    .allowsHitTesting(false)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if let err = playback.errorMessage {
                ErrorPanel(message: err)
            }
        }
        .foregroundStyle(.white)
        .onAppear { scheduleHide() }
        .onChange(of: playback.isPlaying) { scheduleHide() }
    }

    private var controls: some View {
        ZStack {
            // Dim the video a little so controls stay readable.
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                // Top bar
                HStack(spacing: 14) {
                    CloseButton()
                    VStack(alignment: .leading, spacing: 2) {
                        if let item = playback.current {
                            Text(item.type == "episode" ? (item.title ?? "") : item.displayTitle)
                                .font(.headline).lineLimit(1)
                            if item.type == "episode" {
                                Text("\(item.displayTitle) · \(item.displaySubtitle ?? "")")
                                    .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    TracksMenu(onOpen: { hideTask?.cancel() })
                }
                .padding(.horizontal)

                Spacer()

                // Center transport
                HStack(spacing: 56) {
                    Button { playback.skip(-10); scheduleHide() } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 38, weight: .medium))
                    }
                    Button { playback.togglePlayPause(); scheduleHide() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 52, weight: .bold))
                            .frame(width: 70, height: 70)
                    }
                    Button { playback.skip(10); scheduleHide() } label: {
                        Image(systemName: "goforward.10").font(.system(size: 38, weight: .medium))
                    }
                }

                Spacer()

                // Scrubber
                VStack(spacing: 6) {
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

                    HStack {
                        Text(timeString(scrubbing ? scrubValue : playback.currentTime))
                        Spacer()
                        if playback.bufferedAhead > 1 {
                            Label("\(timeString(playback.bufferedAhead)) loaded", systemImage: "arrow.down.circle")
                                .labelStyle(.titleAndIcon)
                        }
                        Spacer()
                        Text("−" + timeString(playback.duration - (scrubbing ? scrubValue : playback.currentTime)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard playback.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && !scrubbing {
                withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
            }
        }
    }
}

private struct CloseButton: View {
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        Button {
            Task { await playback.stop() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .bold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
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
                .buttonStyle(.borderedProminent).tint(.orange)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

/// Hosts the shared video view that VLC draws into.
struct VideoHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
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

    var body: some View {
        Menu {
            let audio = playback.audioTracks
            if !audio.isEmpty {
                Section("Audio") {
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
                Section("Subtitles") {
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .bold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
    }
}

// MARK: - Car screen remote

/// Phone controls while the video is on the car screen.
struct CarRemoteView: View {
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "car.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("Playing on car screen").font(.headline)
            if let item = playback.current {
                Text(item.type == "episode" ? "\(item.displayTitle) · \(item.displaySubtitle ?? "")" : item.displayTitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if playback.heldForMotion {
                Label("Paused while moving", systemImage: "hand.raised.fill")
                    .foregroundStyle(.yellow)
            }

            if playback.duration > 0 {
                Slider(value: Binding(get: { playback.currentTime },
                                      set: { playback.seek(to: $0) }),
                       in: 0...playback.duration)
                    .tint(.orange)
                HStack {
                    Text(timeString(playback.currentTime))
                    Spacer()
                    Text("−" + timeString(playback.duration - playback.currentTime))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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
            .foregroundStyle(.white)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
