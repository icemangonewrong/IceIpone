import Foundation

/// Downloaded video kept on the phone until it's watched (like the Windows app).
///
/// The stream cache for each video lives in its own folder (Caches/videos/<key>-<size>) and is no longer
/// deleted when the player closes, so reopening a video — even after the app was closed — plays the part
/// already downloaded straight from the phone, with no data used twice. A video's folder is deleted once it's
/// watched; when the total goes over the limit in Settings, the videos played longest ago go first.
enum VideoStore {
    static let choices = [0, 2, 5, 10, 20, 50]     // GB; 0 = off
    private static let lock = NSLock()
    private static var inUse: Set<String> = []

    static var limitGB: Int {
        get { (UserDefaults.standard.object(forKey: "videoStoreGB") as? Int) ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "videoStoreGB"); DispatchQueue.global(qos: .utility).async { trim() } }
    }
    static var enabled: Bool { limitGB > 0 }
    static var limitBytes: Int64 { Int64(limitGB) * 1_000_000_000 }

    static var root: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The folder to keep this video in, or nil when keeping is off or another player already uses it.
    static func claim(key: String, size: Int64) -> URL? {
        guard enabled else { return nil }
        let name = "\(key)-\(size)"
        lock.lock(); defer { lock.unlock() }
        guard !inUse.contains(name) else { return nil }
        inUse.insert(name)
        let d = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        touch(d)
        return d
    }

    static func release(_ dir: URL) {
        lock.lock()
        inUse.remove(dir.lastPathComponent)
        lock.unlock()
        touch(dir)
        DispatchQueue.global(qos: .utility).async { trim() }
    }

    private static func touch(_ d: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: d.path)
    }

    /// Chunk index -> bytes already saved, from an earlier session.
    static func savedChunks(in dir: URL) -> [Int64: Int64] {
        var out: [Int64: Int64] = [:]
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            guard f.pathExtension == "bin", let i = Int64(f.deletingPathExtension().lastPathComponent),
                  let n = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, n > 0 else { continue }
            out[i] = Int64(n)
        }
        return out
    }

    /// Watched: delete what was kept for it.
    static func drop(key: String) {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where d.lastPathComponent.hasPrefix("\(key)-") {
            lock.lock(); let busy = inUse.contains(d.lastPathComponent); lock.unlock()
            if busy { continue }      // still open: deleted next time it's watched or trimmed
            try? fm.removeItem(at: d)
            IceLog.info("Saved video: watched, deleted \(key)")
        }
    }

    private static func folderSize(_ d: URL) -> Int64 {
        let fm = FileManager.default
        var n: Int64 = 0
        for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            n += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return n
    }

    static func usageBytes() -> Int64 {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).reduce(0) { $0 + folderSize($1) }
    }

    /// Over the limit: delete the videos played longest ago until it fits (never one that's open).
    static func trim() {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 < $1.1 }
        var total = dirs.reduce(Int64(0)) { $0 + folderSize($1.0) }
        let limit = limitBytes
        guard total > limit else { return }
        for (d, _) in dirs {
            if total <= limit * 95 / 100 { break }
            lock.lock(); let busy = inUse.contains(d.lastPathComponent); lock.unlock()
            if busy { continue }
            let n = folderSize(d)
            try? fm.removeItem(at: d)
            total -= n
            IceLog.info("Saved video: over \(limitGB) GB, deleted \(d.lastPathComponent) (played longest ago)")
        }
    }

    static func clear() {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            lock.lock(); let busy = inUse.contains(d.lastPathComponent); lock.unlock()
            if !busy { try? fm.removeItem(at: d) }
        }
    }
}
