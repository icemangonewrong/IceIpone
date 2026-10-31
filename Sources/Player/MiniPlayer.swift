import SwiftUI

/// Small player along the bottom of the app after pressing the down arrow in the player:
/// live picture, title, play/pause and stop. Tap the picture or title to open the full player.
struct MiniPlayer: View {
    @EnvironmentObject var playback: PlaybackManager
    /// Bumped shortly after appearing so the picture moves here once the full player has finished closing.
    @State private var attachKey = 0

    static let height: CGFloat = 64
    /// How far above the bottom safe area the tab bar reaches.
    static let tabBarClearance: CGFloat = 66

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { playback.expand() } label: {
                    HStack(spacing: 12) {
                        picture
                            .frame(width: 88, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            if let item = playback.current {
                                Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(item.type == "episode" ? (item.displaySubtitle ?? "") : timeString(playback.currentTime)
                                     + " / " + timeString(playback.duration))
                                    .font(.caption).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .plainButton()

                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Button { Task { await playback.stop() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 7)
            .frame(height: Self.height - 3)

            // progress along the bottom edge
            GeometryReader { geo in
                let p = playback.duration > 0 ? min(playback.currentTime / playback.duration, 1) : 0
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.2))
                    Rectangle().fill(Color.ice).frame(width: geo.size.width * p)
                }
            }
            .frame(height: 3)
        }
        .foregroundColor(.white)
        .bg(Color(white: 0.11), RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
        .taskCompat {
            for delay in [0.4, 0.9, 1.6] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attachKey += 1
            }
        }
    }

    @ViewBuilder private var picture: some View {
        if playback.carScreenActive {
            // The video is on the car screen; don't pull it back to the phone.
            ZStack {
                Color.black
                Image(systemName: "car.fill").foregroundColor(Color.ice)
            }
        } else {
            ZStack {
                VideoHost(attachKey: attachKey)
                if playback.isBuffering { OrangeSpinner(size: 22) }
            }
        }
    }
}

extension View {
    /// Leaves room at the bottom of a tab so the mini player doesn't cover the last row.
    func miniPlayerSpace() -> some View { modifier(MiniPlayerSpace()) }
}

private struct MiniPlayerSpace: ViewModifier {
    @EnvironmentObject var playback: PlaybackManager

    func body(content: Content) -> some View {
        content.bottomInset(playback.isActive && !playback.showPlayerUI ? MiniPlayer.height + 26 : 0)
    }
}
