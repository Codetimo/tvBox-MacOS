import Foundation

struct TVSource: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var location: URL
    var kind: SourceKind
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, location: URL, kind: SourceKind, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.location = location
        self.kind = kind
        self.updatedAt = updatedAt
    }
}

enum SourceKind: String, Codable, Hashable {
    case m3u
    case tvboxJSON
}

struct TVChannel: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var group: String
    var logoURL: URL?
    var streamURL: URL
    var headers: [String: String]
}

struct SourceSnapshot: Codable, Hashable {
    var source: TVSource
    var channels: [TVChannel]
    var fetchedAt: Date
    var parserVersion: String
    var warnings: [String]
}
