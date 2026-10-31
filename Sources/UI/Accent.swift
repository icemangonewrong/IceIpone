import SwiftUI

/// The accent color (orange by default), picked in Settings.
enum Accent {
    static let key = "accentColor"
    static let defaultHex = "#ff8c00"
    static let choices: [(name: String, hex: String)] = [
        ("Orange", "#ff8c00"),
        ("Red", "#e5383b"),
        ("Pink", "#ff4f9a"),
        ("Purple", "#9b5cff"),
        ("Blue", "#2f8cff"),
        ("Teal", "#14b8a6"),
        ("Green", "#3cc45a"),
        ("Gold", "#f5c518"),
    ]
    static var hex: String { UserDefaults.standard.string(forKey: key) ?? defaultHex }
    static func name(for hex: String) -> String {
        choices.first { $0.hex.lowercased() == hex.lowercased() }?.name ?? "Custom"
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0xff8c00
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255,
                  opacity: 1)
    }

    /// The app's accent color.
    static var ice: Color { Color(hex: Accent.hex) }
}

/// Row of color dots for Settings.
struct AccentPicker: View {
    @AppStorage(Accent.key) private var accentHex = Accent.defaultHex

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Accent.choices, id: \.hex) { choice in
                    let on = choice.hex.lowercased() == accentHex.lowercased()
                    Button {
                        accentHex = choice.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: choice.hex))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.white, lineWidth: on ? 3 : 0))
                            .padding(2)
                    }
                    .plainButton()
                    .accessibilityLabel(choice.name)
                }
            }
            Text(Accent.name(for: accentHex)).font(.footnote).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
