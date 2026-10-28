import Foundation

// MARK: - Lenient value helpers

/// Plex sometimes sends IDs as numbers and sometimes as strings. This accepts either.
struct FlexString: Codable, Hashable {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = String(i)
        } else if let d = try? c.decode(Double.self) {
            value = String(Int(d))
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

// MARK: - Containers

struct PlexResponse<T: Decodable>: Decodable {
    let MediaContainer: T
}

struct MetadataContainer: Decodable {
    let size: Int?
    let totalSize: Int?
    let Metadata: [PlexItem]?
}

struct SectionsContainer: Decodable {
    let Directory: [PlexSection]?
}

struct HubsContainer: Decodable {
    let Hub: [PlexHub]?
}

// MARK: - Library sections

struct PlexSection: Decodable, Identifiable, Hashable {
    let key: String
    let title: String
    let type: String

    var id: String { key }
    var isVideo: Bool { type == "movie" || type == "show" }
}

// MARK: - Hubs

struct PlexHub: Decodable, Identifiable {
    let hubIdentifier: String?
    let title: String?
    let type: String?
    let key: String?
    let Metadata: [PlexItem]?

    var id: String { hubIdentifier ?? title ?? UUID().uuidString }
}

// MARK: - Items

struct PlexPart: Decodable, Hashable {
    let key: String?
    let container: String?
    let duration: Int?
    let size: Int64?
}

struct PlexMedia: Decodable, Hashable {
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Int?
    let videoResolution: String?
    let videoDynamicRange: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let Part: [PlexPart]?
}

/// Genre, director, etc. Plex sends these as [{"tag": "Drama"}, ...].
struct PlexTag: Decodable, Hashable {
    let tag: String
}

struct PlexRole: Decodable, Hashable {
    let tag: String
    let role: String?
}

struct PlexItem: Decodable, Identifiable, Hashable {
    let ratingKey: FlexString
    let key: String?
    let type: String?
    let title: String?
    let summary: String?
    let year: Int?
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let grandparentRatingKey: FlexString?
    let parentRatingKey: FlexString?
    let index: Int?
    let parentIndex: Int?
    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let librarySectionID: FlexString?
    let addedAt: Int?
    let contentRating: String?
    let audienceRating: Double?
    let rating: Double?
    let tagline: String?
    let studio: String?
    let grandparentArt: String?
    let childCount: Int?
    let Media: [PlexMedia]?
    let Genre: [PlexTag]?
    let Director: [PlexTag]?
    let Role: [PlexRole]?

    var id: String { ratingKey.value }

    var isPlayable: Bool { type == "movie" || type == "episode" }

    /// Title line shown under a poster.
    var displayTitle: String {
        if type == "episode", let show = grandparentTitle { return show }
        return title ?? "Untitled"
    }

    /// Second line, e.g. "S2 · E5 · Episode name" or the year.
    var displaySubtitle: String? {
        if type == "episode" {
            var parts: [String] = []
            if let s = parentIndex { parts.append("S\(s)") }
            if let e = index { parts.append("E\(e)") }
            if let t = title { parts.append(t) }
            return parts.joined(separator: " · ")
        }
        if type == "season", let show = parentTitle { return show }
        if let y = year { return String(y) }
        return nil
    }

    /// Poster artwork: show poster for episodes looks better in rows.
    var posterPath: String? {
        if type == "episode" { return grandparentThumb ?? parentThumb ?? thumb }
        return thumb ?? parentThumb
    }

    /// 0...1 progress for the bar under Continue Watching posters.
    var progress: Double? {
        guard let off = viewOffset, let dur = duration, dur > 0, off > 0 else { return nil }
        return min(max(Double(off) / Double(dur), 0), 1)
    }

    var isWatched: Bool {
        if let leafs = leafCount, let viewed = viewedLeafCount { return leafs > 0 && viewed >= leafs }
        return (viewCount ?? 0) > 0
    }

    var firstPart: PlexPart? { Media?.first?.Part?.first }
    var container: String? { Media?.first?.container ?? firstPart?.container }

    static func == (lhs: PlexItem, rhs: PlexItem) -> Bool { lhs.ratingKey == rhs.ratingKey }
    func hash(into hasher: inout Hasher) { hasher.combine(ratingKey) }
}

// MARK: - plex.tv

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexResource: Decodable, Identifiable {
    let name: String
    let provides: String?
    let clientIdentifier: String
    let accessToken: String?
    let owned: Bool?
    let connections: [PlexConnection]?

    var id: String { clientIdentifier }
    var isServer: Bool { (provides ?? "").contains("server") }
}

struct PlexConnection: Decodable, Hashable {
    let uri: String
    let local: Bool?
    let relay: Bool?
}

/// The server we've picked, saved between launches.
struct SavedServer: Codable, Equatable {
    let name: String
    let clientIdentifier: String
    let accessToken: String
    let baseURL: String
    /// All known connection URIs so we can fail over when the truck moves between networks.
    let allURIs: [String]
}
