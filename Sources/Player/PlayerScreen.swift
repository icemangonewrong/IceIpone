import SwiftUI
import AVKit

/// Full-screen player on the phone. When video is on the car screen, shows remote controls instead.
struct PlayerScreen: View {
    @EnvironmentObject var playback: PlaybackManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if playback.carScreenActive {
                CarRemoteView()
            } else if let player = playback.player {
                VideoPlayerController(player: player)
                    .ignoresSafeArea()
            } else if playback.errorMessage == nil {
                ProgressView().tint(.white)
            }

            if let err = playback.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(err).multilineTextAlignment(.center)
                    Button("Close") { closePlayer() }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            // An embedded player has no close button of its own.
            Button { closePlayer() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 3)
            }
            .padding(.top, 8)
            .padding(.leading, 16)
        }
    }

    private func closePlayer() {
        Task { await playback.stop() }
    }
}

/// Wraps Apple's standard player (scrubbing, audio/subtitle menus, AirPlay, PiP).
struct VideoPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

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
                    Text("-" + timeString(playback.duration - playback.currentTime))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 44) {
                Button { playback.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                Button { playback.skip(30) } label: { Image(systemName: "goforward.30") }
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
