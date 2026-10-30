import SwiftUI

/// Orange spinning ring used everywhere instead of the stock gray spinner.
struct OrangeSpinner: View {
    var size: CGFloat = 36
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.ice.opacity(0.2), lineWidth: size * 0.12)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Color.ice, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
        .accessibilityLabel("Loading")
    }
}

/// Scrub bar that shows played (orange), loaded-ahead (light) and the rest (dim), like Plex.
struct ScrubBar: View {
    let current: Double
    let buffered: Double      // seconds loaded past `current`
    let duration: Double
    /// Called while dragging (true) and on release (false) with the target time.
    let onScrub: (_ time: Double, _ dragging: Bool) -> Void

    @State private var dragTime: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(duration, 1)
            let shown = dragTime ?? current
            let playedX = w * CGFloat(min(max(shown / total, 0), 1))
            let bufferX = w * CGFloat(min(max((current + buffered) / total, 0), 1))
            let dragging = dragTime != nil

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white.opacity(0.45))
                    .frame(width: max(bufferX, playedX))
                Capsule().fill(Color.ice)
                    .frame(width: playedX)
                Circle()
                    .fill(Color.ice)
                    .frame(width: dragging ? 22 : 14, height: dragging ? 22 : 14)
                    .offset(x: playedX - (dragging ? 11 : 7))
                    .shadow(radius: 2)
            }
            .frame(height: dragging ? 8 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let t = Double(min(max(v.location.x / w, 0), 1)) * total
                        dragTime = t
                        onScrub(t, true)
                    }
                    .onEnded { v in
                        let t = Double(min(max(v.location.x / w, 0), 1)) * total
                        dragTime = nil
                        onScrub(t, false)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 30)
    }
}
