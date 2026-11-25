import Foundation
import Darwin

/// A screen that takes videos over DLNA / UPnP, like CarTV's "Cast from an app".
struct DLNADevice: Identifiable, Hashable {
    let id: String            // the device's UDN (or its address if it has none)
    let name: String
    let control: URL          // AVTransport control address
    let service: String       // e.g. urn:schemas-upnp-org:service:AVTransport:1
    var location: URL? = nil  // its description page (on this phone: always 127.0.0.1)
}

enum DLNAError: LocalizedError {
    case refused(Int, String)

    var errorDescription: String? {
        switch self {
        case .refused(let code, let detail): return "It answered \(code)\(detail.isEmpty ? "" : " (\(detail))")."
        }
    }
}

/// DLNA / UPnP casting: find screens (SSDP), hand them a video address, and play / pause / seek.
/// CarTV runs on this same phone, so the search also asks the phone itself (127.0.0.1) directly — that works
/// without iOS's multicast permission, which a sideloaded app may not have.
enum DLNA {

    // MARK: Find screens

    private static let lastKey = "castLastLocation"
    /// Where CarTV's player (LyntraPlayer) keeps its description page.
    private static let descriptionPaths = ["/dlna/description.xml?c=1", "/dlna/description.xml", "/description.xml"]

    static func discover(timeout: TimeInterval = 2.5) async -> [DLNADevice] {
        var found: [DLNADevice] = []
        func add(_ locations: [URL]) async {
            await withTaskGroup(of: DLNADevice?.self) { group in
                for loc in locations { group.addTask { try? await DLNA.describe(loc) } }
                for await d in group {
                    if let d, !found.contains(where: { $0.id == d.id }) { found.append(d) }
                }
            }
        }

        // 1. Where it was last time (CarTV keeps its port while it stays open).
        if let s = UserDefaults.standard.string(forKey: lastKey), let u = URL(string: s) {
            await add([u])
            if !found.isEmpty { IceLog.info("CAST: found at the last address") }
        }
        // 2. The usual search.
        if found.isEmpty {
            IceLog.info("CAST search: this phone's addresses \(localIPv4().joined(separator: ", "))")
            let locations = await Task.detached(priority: .userInitiated) { DLNA.ssdpSearch(timeout: timeout) }.value
            IceLog.info("CAST search: \(locations.count) answer(s) \(locations.map(\.absoluteString).joined(separator: " "))")
            await add(locations)
        }
        // 3. CarTV doesn't answer the search from inside the phone: look for its web server on the phone's own ports.
        if found.isEmpty {
            let started = Date()
            let ports = await Task.detached(priority: .userInitiated) { DLNA.openPorts(host: "127.0.0.1", 49152...65535) }.value
            IceLog.info("CAST scan: open ports on this phone \(ports) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
            await add(ports.flatMap { p in descriptionPaths.compactMap { URL(string: "http://127.0.0.1:\(p)\($0)") } })
        }
        if let d = found.first, let loc = d.location { UserDefaults.standard.set(loc.absoluteString, forKey: lastKey) }
        // The phone's own address first (same device), then the rest by name.
        return found.sorted {
            let a = $0.control.host == "127.0.0.1", b = $1.control.host == "127.0.0.1"
            return a != b ? a : $0.name < $1.name
        }
    }

    /// Sends M-SEARCH to this phone (loopback and each of its addresses) and to the multicast group, and
    /// collects the description addresses that come back.
    private static func ssdpSearch(timeout: TimeInterval) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { IceLog.info("CAST search: no socket (errno \(errno))"); return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        let targets = ["127.0.0.1"] + localIPv4() + ["239.255.255.250"]
        let searchFor = ["urn:schemas-upnp-org:service:AVTransport:1",
                         "urn:schemas-upnp-org:device:MediaRenderer:1",
                         "ssdp:all"]
        var failed = Set<String>()
        func sendAll() {
            for ip in targets {
                for st in searchFor {
                    let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\nUSER-AGENT: iOS UPnP/1.1 Ice/1.0\r\n\r\n"
                    var addr = sockaddr_in()
                    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = UInt16(1900).bigEndian
                    inet_pton(AF_INET, ip, &addr.sin_addr)
                    let bytes = Array(msg.utf8)
                    let sent = bytes.withUnsafeBytes { raw -> Int in
                        withUnsafePointer(to: addr) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    if sent < 0 { failed.insert("\(ip) (errno \(errno))") }
                }
            }
        }

        let start = Date()
        sendAll()
        var resent = false
        var found: [URL] = []
        var buf = [UInt8](repeating: 0, count: 8192)
        let cap = buf.count
        while Date().timeIntervalSince(start) < timeout {
            if !resent && Date().timeIntervalSince(start) > 1 { sendAll(); resent = true }   // UDP can drop one
            let n = recv(fd, &buf, cap, 0)
            guard n > 0 else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let u = URL(string: value), !found.contains(u) { found.append(u) }
            }
        }
        if !failed.isEmpty { IceLog.info("CAST search: couldn't send to \(failed.sorted().joined(separator: ", "))") }
        return found
    }

    /// TCP ports accepting connections on `host` (non-blocking connects in small batches; on the phone itself a
    /// closed port answers at once, so the whole range takes a second or two).
    private static func openPorts(host: String, _ range: ClosedRange<Int>) -> [Int] {
        var open: [Int] = []
        let all = Array(range)
        var i = 0
        while i < all.count {
            let batch = all[i..<min(i + 100, all.count)]
            i += 100
            var socks: [(Int32, Int)] = []
            for port in batch {
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                inet_pton(AF_INET, host, &addr.sin_addr)
                let r = withUnsafePointer(to: addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if r == 0 { open.append(port); close(fd) }
                else if errno == EINPROGRESS { socks.append((fd, port)) }
                else { close(fd) }
            }
            // Wait (briefly) for the ones still connecting.
            var fds = socks.map { pollfd(fd: $0.0, events: Int16(POLLOUT), revents: 0) }
            let deadline = Date().addingTimeInterval(0.3)
            var pending = fds.count
            while pending > 0 && Date() < deadline {
                let n = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 50) }
                if n <= 0 { continue }
                pending = 0
                for k in fds.indices {
                    if fds[k].revents != 0 {
                        if fds[k].fd >= 0 {
                            var err: Int32 = 0
                            var len = socklen_t(MemoryLayout<Int32>.size)
                            getsockopt(fds[k].fd, SOL_SOCKET, SO_ERROR, &err, &len)
                            if err == 0 && (fds[k].revents & Int16(POLLOUT)) != 0 { open.append(socks[k].1) }
                            fds[k].fd = -1          // done: poll ignores negative fds
                        }
                    } else if fds[k].fd >= 0 {
                        pending += 1
                    }
                    fds[k].revents = 0
                }
            }
            for (fd, _) in socks { close(fd) }
        }
        return open.sorted()
    }

    /// The phone's own IPv4 addresses (Wi-Fi, hotspot, VPN…), loopback excluded.
    private static func localIPv4() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(host.count)
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, len, nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1", !out.contains(ip) { out.append(ip) }
                }
            }
            cur = p.pointee.ifa_next
        }
        return out
    }

    /// Reads a device's description and returns it if it can play videos (has AVTransport).
    private static func describe(_ location: URL) async throws -> DLNADevice? {
        var req = URLRequest(url: location)
        req.timeoutInterval = 2
        // A description page is a few KB. Stop reading anything that isn't (a port serving a video
        // would otherwise be read into memory until iOS kills the app).
        guard let got = await SmallFetch.get(req, limit: 256 * 1024), got.1 == 200 else { return nil }
        let data = got.0
        let leaves = XMLLeaves.parse(data)
        var name = "", udn = "", base: URL?
        var lastType = ""
        var transport: (URL, String)?
        for (tag, text) in leaves {
            switch tag {
            case "friendlyName" where name.isEmpty: name = text
            case "UDN" where udn.isEmpty: udn = text
            case "URLBase": base = URL(string: text)
            case "serviceType": lastType = text
            case "controlURL" where lastType.contains(":service:AVTransport:") && transport == nil:
                if let u = URL(string: text, relativeTo: base ?? location)?.absoluteURL { transport = (u, lastType) }
            default: break
            }
        }
        guard let found = transport else { return nil }
        let (control, service) = found
        // An address from another interface still means this phone: use loopback, which never changes.
        var ctl = control
        if localIPv4().contains(control.host ?? ""), var c = URLComponents(url: control, resolvingAgainstBaseURL: false) {
            c.host = "127.0.0.1"
            ctl = c.url ?? control
        }
        IceLog.info("CAST found \"\(name)\" at \(ctl.absoluteString)")
        var loc = location
        if ctl.host == "127.0.0.1", var c = URLComponents(url: location, resolvingAgainstBaseURL: false) {
            c.host = "127.0.0.1"
            loc = c.url ?? location
        }
        return DLNADevice(id: udn.isEmpty ? ctl.absoluteString : udn, name: name.isEmpty ? "Screen" : name,
                          control: ctl, service: service, location: loc)
    }

    // MARK: Control

    /// Hands the screen a video address (it fetches the video itself).
    static func load(_ d: DLNADevice, url: URL, title: String, mime: String, duration: Double) async throws {
        let res = "<res protocolInfo=\"http-get:*:\(mime):*\"\(duration > 0 ? " duration=\"\(hms(duration)).000\"" : "")>\(esc(url.absoluteString))</res>"
        let didl = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"ice\" parentID=\"0\" restricted=\"1\"><dc:title>\(esc(title))</dc:title><upnp:class>object.item.videoItem.movie</upnp:class>\(res)</item></DIDL-Lite>"
        _ = try await soap(d, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", didl)], timeout: 12)
    }

    static func play(_ d: DLNADevice) async throws { _ = try await soap(d, "Play", [("InstanceID", "0"), ("Speed", "1")]) }
    static func pause(_ d: DLNADevice) async throws { _ = try await soap(d, "Pause", [("InstanceID", "0")]) }
    static func stop(_ d: DLNADevice) async throws { _ = try await soap(d, "Stop", [("InstanceID", "0")], timeout: 4) }

    static func seek(_ d: DLNADevice, to seconds: Double) async throws {
        _ = try await soap(d, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", hms(seconds))])
    }

    /// PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING or NO_MEDIA_PRESENT.
    static func state(_ d: DLNADevice) async throws -> String {
        let v = try await soap(d, "GetTransportInfo", [("InstanceID", "0")], timeout: 4)
        return v["CurrentTransportState"] ?? ""
    }

    /// Where it is in the video, and how long the video is (seconds; nil when it doesn't say).
    static func position(_ d: DLNADevice) async throws -> (at: Double?, length: Double?) {
        let v = try await soap(d, "GetPositionInfo", [("InstanceID", "0")], timeout: 4)
        return (seconds(v["RelTime"]), seconds(v["TrackDuration"]))
    }

    @discardableResult
    private static func soap(_ d: DLNADevice, _ action: String, _ args: [(String, String)],
                             timeout: TimeInterval = 6) async throws -> [String: String] {
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(d.service)\">"
        for (k, v) in args { body += "<\(k)>\(esc(v))</\(k)>" }
        body += "</u:\(action)></s:Body></s:Envelope>"
        var req = URLRequest(url: d.control)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(d.service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.dataCompat(for: req)
        var values: [String: String] = [:]
        for (k, v) in XMLLeaves.parse(data) where values[k] == nil { values[k] = v }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = [values["errorCode"], values["errorDescription"]].compactMap { $0 }.joined(separator: " ")
            throw DLNAError.refused(code, detail)
        }
        return values
    }

    // MARK: Helpers

    static func mime(forContainer c: String?) -> String {
        switch (c ?? "").lowercased() {
        case "mkv", "matroska": return "video/x-matroska"
        case "mp4", "m4v", "mov": return "video/mp4"
        case "avi": return "video/x-msvideo"
        case "ts", "mpegts": return "video/mp2t"
        case "webm": return "video/webm"
        case "wmv", "asf": return "video/x-ms-wmv"
        default: return "video/mp4"
        }
    }

    static func hms(_ t: Double) -> String {
        let s = Int(max(t, 0))
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// "1:02:03" or "1:02:03.500" → seconds; nil for NOT_IMPLEMENTED or empty.
    static func seconds(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").map { Double($0) }
        guard parts.count == 3, let h = parts[0], let m = parts[1], let sec = parts[2] else { return nil }
        return h * 3600 + m * 60 + sec
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Every text-only element of an XML document as (name without prefix, text), in order.
private final class XMLLeaves: NSObject, XMLParserDelegate {
    private var out: [(String, String)] = []
    private var text = ""
    private var hadChild = false

    static func parse(_ data: Data) -> [(String, String)] {
        let p = XMLParser(data: data)
        let me = XMLLeaves()
        p.delegate = me
        p.parse()
        return me.out
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        hadChild = false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !hadChild {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            out.append((name, text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        text = ""
        hadChild = true
    }
}

/// GET that gives up once the answer is bigger than `limit` bytes (or isn't text/XML), so a stray port
/// that serves a video can't fill the phone's memory.
private final class SmallFetch: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var data = Data()
    private var code = 0
    private var cont: CheckedContinuation<(Data, Int)?, Never>?

    private init(limit: Int) { self.limit = limit }

    static func get(_ req: URLRequest, limit: Int) async -> (Data, Int)? {
        let me = SmallFetch(limit: limit)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = req.timeoutInterval
        cfg.timeoutIntervalForResource = 4
        let session = URLSession(configuration: cfg, delegate: me, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { c in
            me.cont = c
            session.dataTask(with: req).resume()
        }
    }

    private func finish(_ r: (Data, Int)?) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        code = http?.statusCode ?? 0
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if response.expectedContentLength > Int64(limit) || type.hasPrefix("video/") || type.hasPrefix("audio/") {
            completionHandler(.cancel)
            finish(nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
        data.append(d)
        if data.count > limit { dataTask.cancel(); finish(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil ? (data, code) : nil)
    }
}
