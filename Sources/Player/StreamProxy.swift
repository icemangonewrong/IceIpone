import Foundation
import Network

/// A tiny web server inside the app that sits between the video player and Plex.
///
/// It downloads the file ahead of where you're watching into a cache on the phone's
/// storage, and serves the player from that cache. The player only ever talks to this
/// local server, so when cell signal drops the player just keeps reading what's cached;
/// meanwhile the download retries every few seconds and carries on where it stopped.
///
/// All state lives on one serial queue, so there are no locks.
final class StreamProxy: NSObject, URLSessionDataDelegate {

    struct Snapshot {
        var bufferedBytes: Int64 = 0
        var offline = false
        var bytesPerSecond: Double = 1
    }

    // MARK: - Configuration

    private let q = DispatchQueue(label: "carplex.proxy")
    private let remote: URL
    private let size: Int64
    private let mime: String
    let bytesPerSecond: Double
    private let aheadLimit: Int64
    private let behindLimit: Int64 = 300 * 1024 * 1024     // keep ~300 MB behind for rewinding
    private let chunkSize: Int64 = 4 * 1024 * 1024
    private let sendSize: Int64 = 512 * 1024
    private let dir: URL

    // MARK: - State (only touched on `q`)

    private var listener: NWListener?
    /// Chunk index -> number of bytes stored, always contiguous from the chunk's start.
    private var chunks: [Int64: Int64] = [:]
    private var writeHandle: FileHandle?
    private var writeChunk: Int64 = -1

    private final class Job {
        let conn: NWConnection
        var pos: Int64
        let end: Int64          // exclusive
        var sending = false
        init(conn: NWConnection, pos: Int64, end: Int64) { self.conn = conn; self.pos = pos; self.end = end }
    }
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var activeJob: ObjectIdentifier?
    /// Where the player is currently reading.
    private var readPos: Int64 = 0

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var taskStart: Int64 = 0
    private var downloadPos: Int64 = 0
    private var paused = false          // download held because we're far enough ahead
    private var offline = false
    private var retryPending = false
    private var stopped = false

    // MARK: - Setup

    /// - Parameters:
    ///   - aheadSeconds: how much video to keep loaded ahead of the player.
    init(remote: URL, size: Int64, duration: Double, aheadSeconds: Double, container: String?) {
        self.remote = remote
        self.size = size
        self.bytesPerSecond = max(Double(size) / max(duration, 1), 50_000)
        switch (container ?? "").lowercased() {
        case "mkv": mime = "video/x-matroska"
        case "mp4", "m4v": mime = "video/mp4"
        case "mov": mime = "video/quicktime"
        case "avi": mime = "video/x-msvideo"
        default: mime = "application/octet-stream"
        }

        // Don't use more storage than is free (leave 2 GB), and never more than 12 GB.
        var wanted = Int64(bytesPerSecond * max(aheadSeconds, 60))
        let free = StreamProxy.freeSpace()
        if free > 0 { wanted = min(wanted, max(free - 2_000_000_000, 200_000_000)) }
        aheadLimit = min(wanted, 12_000_000_000)

        dir = StreamProxy.cacheRoot.appendingPathComponent("stream-" + UUID().uuidString, isDirectory: true)
        super.init()
    }

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Deletes caches left behind if the app was killed mid-video.
    static func cleanUpOldCaches() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for url in items where url.lastPathComponent.hasPrefix("stream-") {
            try? fm.removeItem(at: url)
        }
    }

    private static func freeSpace() -> Int64 {
        let values = try? cacheRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Starts the local server and returns the address to give the player.
    func start() async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        opQueue.underlyingQueue = q
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }

        final class Once { var done = false }
        let once = Once()
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let err):
                    once.done = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            l.start(queue: q)
        }
        guard port != 0, let url = URL(string: "http://127.0.0.1:\(port)/media") else {
            throw URLError(.cannotConnectToHost)
        }
        // Start filling the cache right away.
        q.async { self.runDownload(from: 0) }
        return url
    }

    /// Stops everything and deletes the cache. Safe to call from any thread.
    func stop() {
        q.sync {
            stopped = true
            task?.cancel()
            task = nil
            session?.invalidateAndCancel()
            session = nil
            listener?.cancel()
            listener = nil
            for job in jobs.values { job.conn.cancel() }
            jobs.removeAll()
            try? writeHandle?.close()
            writeHandle = nil
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func snapshot() -> Snapshot {
        q.sync {
            Snapshot(bufferedBytes: available(from: readPos), offline: offline, bytesPerSecond: bytesPerSecond)
        }
    }

    // MARK: - Cache bookkeeping

    private func chunkURL(_ i: Int64) -> URL { dir.appendingPathComponent("\(i).bin") }

    private func chunkLength(_ i: Int64) -> Int64 { min(chunkSize, size - i * chunkSize) }

    /// Number of cached bytes available in a row starting at `pos`.
    private func available(from pos: Int64) -> Int64 {
        var p = pos
        var total: Int64 = 0
        while p < size {
            let ci = p / chunkSize
            let have = chunks[ci] ?? 0
            let within = p - ci * chunkSize
            if have <= within { break }
            let n = have - within
            total += n
            p += n
            if have < chunkLength(ci) { break }
        }
        return total
    }

    /// First byte at or before the end of the cached run that starts at `pos`, where a download should begin.
    private func firstMissing(from pos: Int64) -> Int64 {
        var ci = max(pos, 0) / chunkSize
        while ci * chunkSize < size, (chunks[ci] ?? 0) >= chunkLength(ci) { ci += 1 }
        return min(ci * chunkSize + (chunks[ci] ?? 0), size)
    }

    private func readCached(at pos: Int64, max n: Int64) -> Data? {
        let ci = pos / chunkSize
        let have = chunks[ci] ?? 0
        let within = pos - ci * chunkSize
        let count = min(n, have - within)
        guard count > 0, let h = try? FileHandle(forReadingFrom: chunkURL(ci)) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(within))
            return try h.read(upToCount: Int(count))
        } catch {
            return nil
        }
    }

    /// Writes downloaded bytes that start at `offset` (always the contiguous end of a chunk).
    private func store(_ data: Data, at offset: Int64) {
        var off = offset
        var idx = 0
        while idx < data.count {
            let ci = off / chunkSize
            let within = off - ci * chunkSize
            let n = Int(min(Int64(data.count - idx), chunkSize - within))
            let have = chunks[ci] ?? 0
            if within + Int64(n) > have {
                // Skip any part we already have, append the rest.
                let skip = Int(max(have - within, 0))
                if within <= have {
                    append(data.subdata(in: (idx + skip)..<(idx + n)), toChunk: ci)
                    chunks[ci] = within + Int64(n)
                }
            }
            off += Int64(n)
            idx += n
        }
    }

    private func append(_ data: Data, toChunk ci: Int64) {
        if writeChunk != ci || writeHandle == nil {
            try? writeHandle?.close()
            let url = chunkURL(ci)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            writeHandle = try? FileHandle(forWritingTo: url)
            writeChunk = ci
        }
        guard let h = writeHandle else { return }
        do {
            _ = try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            try? h.close()
            writeHandle = nil
        }
    }

    /// Frees storage once the cache is over budget, dropping chunks farthest from the
    /// player first (behind counts double). Chunks around the player are never dropped,
    /// so VLC peeking at the end of an MKV file doesn't wipe out the start.
    private func trim() {
        let budget = aheadLimit + behindLimit
        var total = chunks.values.reduce(0, +)
        guard total > budget else { return }
        let protectLow = readPos - 64 * 1024 * 1024
        let protectHigh = readPos + aheadLimit
        func distance(_ ci: Int64) -> Int64 {
            let s = ci * chunkSize
            return s < readPos ? (readPos - s) * 2 : s - readPos
        }
        for ci in chunks.keys.sorted(by: { distance($0) > distance($1) }) {
            guard total > budget else { break }
            let s = ci * chunkSize
            if s + chunkSize > protectLow && s < protectHigh { continue }
            total -= chunks[ci] ?? 0
            chunks[ci] = nil
            if ci == writeChunk { try? writeHandle?.close(); writeHandle = nil; writeChunk = -1 }
            try? FileManager.default.removeItem(at: chunkURL(ci))
        }
    }

    // MARK: - Downloading from Plex

    private func runDownload(from pos: Int64) {
        guard !stopped, let session else { return }
        task?.cancel()
        task = nil
        paused = false
        let start = firstMissing(from: pos)
        guard start < size else { return }

        var req = URLRequest(url: remote)
        req.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        req.timeoutInterval = 20
        taskStart = start
        downloadPos = start
        let t = session.dataTask(with: req)
        task = t
        t.resume()
    }

    /// Makes sure something is downloading toward `pos`.
    private func ensureDownloading(toward pos: Int64) {
        if retryPending { return }  // a retry is already scheduled and will start from the player's spot
        if let _ = task, taskStart <= pos, pos <= downloadPos + chunkSize * 2 {
            if paused { task?.resume(); paused = false }
            return
        }
        runDownload(from: pos)
    }

    private func scheduleRetry() {
        guard !stopped, !retryPending else { return }
        retryPending = true
        q.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.stopped else { return }
            self.retryPending = false
            self.runDownload(from: self.readPos)
        }
    }

    private func throttle() {
        guard let t = task else { return }
        let ahead = downloadPos - readPos
        if !paused && ahead > aheadLimit {
            t.suspend()
            paused = true
        } else if paused && ahead < aheadLimit * 9 / 10 {
            t.resume()
            paused = false
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task else { completionHandler(.cancel); return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 206 = partial content as asked. 200 is only OK if we asked from the very beginning.
        if code == 206 || (code == 200 && taskStart == 0) {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
            task = nil
            scheduleRetry()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, !stopped else { return }
        store(data, at: downloadPos)
        downloadPos += Int64(data.count)
        offline = false
        pumpAll()
        throttle()
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task, !stopped else { return }
        task = nil
        if let err = error as? URLError, err.code == .cancelled { return }
        if paused {
            // The server gave up on our held connection. Not a signal problem; resume later.
            paused = false
            return
        }
        if error != nil {
            offline = true
            scheduleRetry()
        } else if downloadPos < size {
            // Server ended early; keep going.
            scheduleRetry()
        }
    }

    // MARK: - Serving the player

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeJob(ObjectIdentifier(conn))
            default:
                break
            }
        }
        conn.start(queue: q)
        receiveHeader(conn, buffer: Data())
    }

    private func receiveHeader(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handleRequest(conn, header: String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self))
            } else if err != nil || done || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.receiveHeader(conn, buffer: buf)
            }
        }
    }

    private func handleRequest(_ conn: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"

        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        for line in lines where line.lowercased().hasPrefix("range:") {
            // "Range: bytes=START-END" (END optional)
            if let eq = line.firstIndex(of: "=") {
                let spec = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                if let s = parts.first, let v = Int64(s.trimmingCharacters(in: .whitespaces)) {
                    start = v
                    partial = true
                }
                if parts.count > 1, let e = Int64(parts[1].trimmingCharacters(in: .whitespaces)) {
                    end = min(e, size - 1)
                }
            }
        }

        if start >= size || start > end {
            let resp = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        var resp = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        resp += "Content-Type: \(mime)\r\n"
        resp += "Accept-Ranges: bytes\r\n"
        resp += "Content-Length: \(end - start + 1)\r\n"
        if partial { resp += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        resp += "Connection: close\r\n\r\n"

        if method == "HEAD" {
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        let job = Job(conn: conn, pos: start, end: end + 1)
        let id = ObjectIdentifier(conn)
        jobs[id] = job
        activeJob = id
        readPos = start
        job.sending = true
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            job.sending = false
            if err != nil { conn.cancel(); self.removeJob(id); return }
            self.pump(job)
        })
        ensureDownloading(toward: start)
    }

    /// Forget a finished/closed connection. If it was the one the player was reading from,
    /// hand that role to another open connection so downloads keep following the player.
    private func removeJob(_ id: ObjectIdentifier) {
        jobs[id] = nil
        if activeJob == id {
            activeJob = jobs.values.max(by: { $0.pos < $1.pos }).map { ObjectIdentifier($0.conn) }
            if let a = activeJob, let j = jobs[a] {
                readPos = j.pos
                pump(j)  // resumes it, or points the download back at it if it needs data
            }
        }
    }

    private func pumpAll() {
        for job in jobs.values where !job.sending { pump(job) }
    }

    private func pump(_ job: Job) {
        let id = ObjectIdentifier(job.conn)
        guard !job.sending, jobs[id] != nil, !stopped else { return }

        if job.pos >= job.end {
            removeJob(id)
            job.conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in job.conn.cancel() })
            return
        }

        let avail = available(from: job.pos)
        if avail <= 0 {
            // Not downloaded yet: the player waits here (it shows as buffering) instead of failing.
            if id == activeJob { ensureDownloading(toward: job.pos) }
            return
        }

        let n = min(avail, sendSize, job.end - job.pos)
        guard let data = readCached(at: job.pos, max: n), !data.isEmpty else { return }
        job.sending = true
        job.conn.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            job.sending = false
            if err != nil {
                job.conn.cancel()
                self.removeJob(id)
                return
            }
            job.pos += Int64(data.count)
            if id == self.activeJob {
                self.readPos = job.pos
                self.trim()
                self.throttle()
                if self.task == nil && !self.retryPending && self.available(from: self.readPos) < self.aheadLimit * 9 / 10 {
                    self.runDownload(from: self.readPos)
                }
            }
            self.pump(job)
        })
    }
}
