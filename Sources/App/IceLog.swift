import Foundation
import UIKit

/// Ice's log file, for tracking down playback problems: Settings → Share log file.
/// Kept in the app's Documents folder as ice.log (the previous one rolls over to ice.old.log at 2 MB).
enum IceLog {
    private static let q = DispatchQueue(label: "ice.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var file: URL { dir.appendingPathComponent("ice.log") }
    static var oldFile: URL { dir.appendingPathComponent("ice.old.log") }

    static func info(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        q.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: oldFile)
                try? fm.moveItem(at: file, to: oldFile)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                h.closeFile()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    static func started() {
        let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let d = UIDevice.current
        info(String(repeating: "=", count: 60))
        info("Ice build \(v) starting · \(d.model) · iOS \(d.systemVersion)")
    }

    /// Files to share (newest first), so the person can send them.
    static func filesToShare() -> [URL] {
        q.sync {}
        return [file, oldFile].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
