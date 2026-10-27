import SwiftUI
import AVKit

/// Full-screen player on the phone. When video is on the car screen, shows remote controls instead.
struct PlayerScreen: View {
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if playback.carScreenActive {
                CarRemoteView()
                    .overlay(alignment: .topLeading) { CloseButton().padding() }
            } else if let player = playback.player {
                PlayerView(player: player)
            } else if let err = playback.errorMessage {
                ErrorPanel(message: err)
            } else {
                ProgressView().tint(.white).controlSize(.large)
                CloseButton()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(playback.player != nil && !playback.carScreenActive)
    }
}

// MARK: - Video + controls

private struct PlayerView: View {
    @EnvironmentObject var playback: PlaybackManager
    let player: AVPlayer

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        ZStack {
            VideoLayerView(player: player)
                .ignoresSafeArea()

            // Tap anywhere to show/hide controls.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                    scheduleHide()
                }

            if playback.isBuffering && !scrubbing {
                ProgressView().tint(.white).controlSize(.large)
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
        .onChange(of: playback.isPlaying) { _ in scheduleHide() }
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
                    RoutePicker()
                        .frame(width: 44, height: 44)
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
                    Slider(value: Binding(
                        get: { scrubbing ? scrubValue : playback.currentTime },
                        set: { scrubValue = $0 }
                    ), in: 0...max(playback.duration, 1), onEditingChanged: { editing in
                        if editing {
                            scrubValue = playback.currentTime
                            scrubbing = true
                            hideTask?.cancel()
                        } else {
                            playback.seek(to: scrubValue)
                            scrubbing = false
                            scheduleHide()
                        }
                    })
                    .tint(.orange)

                    HStack {
                        Text(timeString(scrubbing ? scrubValue : playback.currentTime))
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

/// The video itself, drawn with an AVPlayerLayer.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// AirPlay button.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.tintColor = .white
        v.activeTintColor = .systemOrange
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
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
