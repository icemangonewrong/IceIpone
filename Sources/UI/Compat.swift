import SwiftUI
import UIKit

// Small helpers so the same screens work on iOS 14 and look the same as before on newer iOS.
// Each one uses the newer SwiftUI feature when it's available and an iOS 14 equivalent otherwise.

// MARK: - Navigation

/// NavigationStack on iOS 16+, NavigationView (single column) on older iOS.
struct NavStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

// MARK: - View modifiers

extension View {
    /// `.task` on iOS 15+, onAppear + Task on iOS 14.
    @ViewBuilder
    func taskCompat(_ action: @escaping @Sendable () async -> Void) -> some View {
        if #available(iOS 15.0, *) {
            task(action)
        } else {
            modifier(AppearTask(action: action))
        }
    }

    /// `.task(id:)` on iOS 15+; on iOS 14 runs on appear and again whenever `id` changes.
    @ViewBuilder
    func taskCompat<T: Equatable>(id: T, _ action: @escaping @Sendable () async -> Void) -> some View {
        if #available(iOS 15.0, *) {
            task(id: id, action)
        } else {
            modifier(AppearTask(action: action)).onChange(of: id) { _ in Task { await action() } }
        }
    }

    /// Accent color for controls (buttons, toggles, progress bars).
    @ViewBuilder
    func iceTint(_ color: Color) -> some View {
        if #available(iOS 15.0, *) {
            tint(color)
        } else {
            accentColor(color)
        }
    }

    /// Two-color SF Symbol (e.g. white check on an accent circle). iOS 14 draws it in the second color.
    @ViewBuilder
    func palette(_ primary: Color, _ secondary: Color) -> some View {
        if #available(iOS 15.0, *) {
            foregroundStyle(primary, secondary)
        } else {
            foregroundColor(secondary)
        }
    }

    /// Color behind a view, clipped to a shape.
    func bg<S: Shape>(_ color: Color, _ shape: S) -> some View {
        background(shape.fill(color))
    }

    /// Frosted background on iOS 15+, dark translucent on iOS 14.
    @ViewBuilder
    func frosted<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 15.0, *) {
            background(.ultraThinMaterial, in: shape)
        } else {
            background(shape.fill(Color.black.opacity(0.55)))
        }
    }

    /// `.overlay(alignment:) { }` that also works on iOS 14.
    func overlayCompat<V: View>(alignment: Alignment = .center, @ViewBuilder _ content: () -> V) -> some View {
        overlay(content(), alignment: alignment)
    }

    /// Filled button in the accent color.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(iOS 15.0, *) {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(FilledButtonStyle())
        }
    }

    /// Light gray button.
    @ViewBuilder
    func borderedButton() -> some View {
        if #available(iOS 15.0, *) {
            buttonStyle(.bordered)
        } else {
            buttonStyle(GrayButtonStyle())
        }
    }

    /// Plain button (no highlight styling).
    func plainButton() -> some View {
        buttonStyle(PlainButtonStyle())
    }

    /// Button with no border inside lists.
    func borderlessButton() -> some View {
        buttonStyle(BorderlessButtonStyle())
    }

    @ViewBuilder
    func largeControl() -> some View {
        if #available(iOS 15.0, *) {
            controlSize(.large)
        } else {
            self
        }
    }

    @ViewBuilder
    func selectableText() -> some View {
        if #available(iOS 15.0, *) {
            textSelection(.enabled)
        } else {
            self
        }
    }

    /// Pull down to refresh (iOS 15+; not available on iOS 14).
    @ViewBuilder
    func refreshableCompat(_ action: @escaping @Sendable () async -> Void) -> some View {
        if #available(iOS 15.0, *) {
            refreshable(action: action)
        } else {
            self
        }
    }

    /// Search box: the system search bar on iOS 15+, a text field above the content on iOS 14.
    @ViewBuilder
    func searchCompat(text: Binding<String>, prompt: String) -> some View {
        if #available(iOS 15.0, *) {
            searchable(text: text, prompt: Text(prompt))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(prompt, text: text)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                self
            }
        }
    }

    /// Half-height sheet on iOS 16+; full sheet on older iOS.
    @ViewBuilder
    func sheetHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.height(height)])
        } else {
            self
        }
    }

    /// Adds space at the bottom (safeAreaInset on iOS 15+, padding on iOS 14).
    @ViewBuilder
    func bottomInset(_ height: CGFloat) -> some View {
        if #available(iOS 15.0, *) {
            safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: height) }
        } else {
            padding(.bottom, height)
        }
    }
}

private struct AppearTask: ViewModifier {
    let action: @Sendable () async -> Void
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { task = Task { await action() } }
            .onDisappear { task?.cancel() }
    }
}

// MARK: - Button styles for iOS 14

struct FilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ice.opacity(configuration.isPressed ? 0.7 : (enabled ? 1 : 0.4))))
    }
}

struct GrayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(Color.ice)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
    }
}

// MARK: - Images

/// Loads an image from a URL (AsyncImage on iOS 15+ does the same; this works on iOS 14 too).
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @StateObject private var loader = ImageLoader()

    var body: some View {
        Group {
            if let img = loader.image {
                Image(uiImage: img).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { loader.load($0) }
    }
}

final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var current: URL?
    private var task: URLSessionDataTask?

    static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()

    func load(_ url: URL?) {
        guard url != current else { return }
        current = url
        task?.cancel()
        guard let url else { image = nil; return }
        if let hit = Self.cache.object(forKey: url as NSURL) {
            image = hit
            return
        }
        image = nil
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            Self.cache.setObject(img, forKey: url as NSURL, cost: data.count)
            DispatchQueue.main.async {
                guard let self, self.current == url else { return }
                self.image = img
            }
        }
        task?.resume()
    }
}

// MARK: - Networking

extension URLSession {
    /// async data(for:) that also works on iOS 14.
    func dataCompat(for request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(iOS 15.0, *) {
            return try await data(for: request)
        }
        return try await withCheckedThrowingContinuation { cont in
            let task = dataTask(with: request) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (data ?? Data(), response ?? URLResponse()))
                }
            }
            task.resume()
        }
    }

    func dataCompat(from url: URL) async throws -> (Data, URLResponse) {
        try await dataCompat(for: URLRequest(url: url))
    }
}
