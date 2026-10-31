import Foundation
import UIKit

/// Saves the reason when the app crashes, so it can be read in Settings after reopening.
enum CrashNote {
    private static let key = "lastCrashNote"
    private static var fd: Int32 = -1
    private static var path: String {
        (NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory())
            + "/last-crash.txt"
    }

    /// The saved note from the last crash, if any.
    static var last: String? {
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        if let s = try? String(contentsOfFile: path, encoding: .utf8), !s.isEmpty { return s }
        return nil
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        try? FileManager.default.removeItem(atPath: path)
        open()
    }

    static func install() {
        open()
        NSSetUncaughtExceptionHandler { e in
            let when = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            let text = "\(when)\n\(e.name.rawValue): \(e.reason ?? "")\n\n"
                + e.callStackSymbols.prefix(25).joined(separator: "\n")
            UserDefaults.standard.set(text, forKey: CrashNote.key)
            UserDefaults.standard.synchronize()
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                CrashNote.writeSignal(s)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static func open() {
        // Opened ahead of time so the crash handler only has to write.
        if fd >= 0 { close(fd) }
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    private static func writeSignal(_ s: Int32) {
        guard fd >= 0 else { return }
        let names: [Int32: String] = [SIGABRT: "SIGABRT (abort)", SIGSEGV: "SIGSEGV (bad memory access)",
                                      SIGBUS: "SIGBUS", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP (Swift runtime error)",
                                      SIGFPE: "SIGFPE"]
        let text = "Crash: \(names[s] ?? "signal \(s)")\n" + Thread.callStackSymbols.prefix(25).joined(separator: "\n") + "\n\n"
        text.withCString { p in _ = write(fd, p, strlen(p)) }
    }
}
