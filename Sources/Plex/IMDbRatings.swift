import Foundation

/// IMDb scores for everything, from IMDb's own free daily ratings file
/// (https://datasets.imdbws.com/title.ratings.tsv.gz, free for personal use). Plex only has the IMDb score when a
/// library's ratings source is set to IMDb, never for seasons and often not in lists; this covers every movie, show
/// and episode by IMDb ID (tt1234567), which Plex and Seerr both give. Downloaded about once a day (~8 MB) and kept
/// as two compact sorted arrays (~8 MB in memory), saved to the phone so later launches load it instantly.
final class IMDbRatings: ObservableObject {
    static let shared = IMDbRatings()
    static let source = URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz")!

    /// Bumped whenever new ratings are loaded, so posters redraw with them.
    @Published private(set) var version = 0

    private var ids: [UInt32] = []
    private var vals: [UInt8] = []
    private let lock = NSLock()
    private var started = false

    private var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("imdb")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func rating(_ imdbID: String?) -> Double? {
        guard let s = imdbID, s.hasPrefix("tt"), let n = UInt32(s.dropFirst(2)) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var lo = 0, hi = ids.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let v = ids[mid]
            if v == n { return Double(vals[mid]) / 10 }
            if v < n { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.loadSaved() { self.bump() }
            if self.age() > 24 * 3600 || self.ids.isEmpty {
                Task { await self.download() }
            }
        }
    }

    private func bump() {
        DispatchQueue.main.async { self.version += 1 }
    }

    private func age() -> TimeInterval {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("stamp")), let t = Double(s) else { return .infinity }
        return Date().timeIntervalSince1970 - t
    }

    private func loadSaved() -> Bool {
        guard let a = try? Data(contentsOf: dir.appendingPathComponent("ids.bin")),
              let b = try? Data(contentsOf: dir.appendingPathComponent("ratings.bin")),
              a.count == b.count * 4, !b.isEmpty else { return false }
        let newIDs = a.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let newVals = [UInt8](b)
        lock.lock()
        ids = newIDs
        vals = newVals
        lock.unlock()
        return true
    }

    private func download() async {
        do {
            let (data, resp) = try await URLSession.shared.dataCompat(from: Self.source)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let tsv = Self.gunzip(data) else { return }
            var newIDs: [UInt32] = []
            var newVals: [UInt8] = []
            newIDs.reserveCapacity(1_700_000)
            newVals.reserveCapacity(1_700_000)
            tsv.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                let p = buf.bindMemory(to: UInt8.self)
                var i = 0
                let n = p.count
                while i < n {
                    // line: tt0000001<TAB>5.7<TAB>2100<LF>
                    if i + 2 < n, p[i] == 0x74, p[i + 1] == 0x74 {
                        i += 2
                        var id: UInt32 = 0
                        while i < n, p[i] >= 0x30, p[i] <= 0x39 { id = id &* 10 &+ UInt32(p[i] - 0x30); i += 1 }
                        if i < n, p[i] == 0x09 {
                            i += 1
                            var whole = 0, tenth = 0
                            while i < n, p[i] >= 0x30, p[i] <= 0x39 { whole = whole * 10 + Int(p[i] - 0x30); i += 1 }
                            if i < n, p[i] == 0x2E, i + 1 < n { tenth = Int(p[i + 1] &- 0x30); i += 2 }
                            newIDs.append(id)
                            newVals.append(UInt8(max(0, min(100, whole * 10 + tenth))))
                        }
                    }
                    while i < n, p[i] != 0x0A { i += 1 }
                    i += 1
                }
            }
            guard !newIDs.isEmpty else { return }
            if zip(newIDs, newIDs.dropFirst()).contains(where: { $0 >= $1 }) {   // IMDb's file is sorted; just in case
                let order = newIDs.indices.sorted { newIDs[$0] < newIDs[$1] }
                newIDs = order.map { newIDs[$0] }
                newVals = order.map { newVals[$0] }
            }
            let idData = newIDs.withUnsafeBufferPointer { Data(buffer: $0) }
            try? idData.write(to: dir.appendingPathComponent("ids.bin"), options: .atomic)
            try? Data(newVals).write(to: dir.appendingPathComponent("ratings.bin"), options: .atomic)
            try? String(Date().timeIntervalSince1970).write(to: dir.appendingPathComponent("stamp"), atomically: true,
                                                            encoding: .utf8)
            lock.lock()
            ids = newIDs
            vals = newVals
            lock.unlock()
            bump()
        } catch {
            print("IMDb ratings download:", error)
        }
    }

    /// .gz -> bytes (the gzip wrapper around raw DEFLATE, which Foundation can inflate).
    static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flg = b[3]
        var i = 10
        if flg & 4 != 0 { i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flg & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flg & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flg & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let body = Data(b[i..<(b.count - 8)])
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}
