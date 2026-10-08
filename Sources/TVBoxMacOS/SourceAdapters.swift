import Foundation

enum SourceParseError: LocalizedError {
    case invalidInput(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .unsupported(let message): return message
        }
    }
}

protocol SourceAdapter {
    func parse(data: Data, source: TVSource) throws -> SourceSnapshot
}

struct M3UAdapter: SourceAdapter {
    let maxBytes = 10 * 1024 * 1024
    let maxChannels = 20_000

    func parse(data: Data, source: TVSource) throws -> SourceSnapshot {
        guard data.count <= maxBytes else {
            throw SourceParseError.invalidInput("M3U source exceeds the 10 MB safety limit.")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw SourceParseError.invalidInput("M3U source is not valid UTF-8/UTF-16 text.")
        }

        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.uppercased().hasPrefix("#EXTM3U") == true else {
            throw SourceParseError.invalidInput("Expected an extended M3U header.")
        }

        var channels: [TVChannel] = []
        var pending: (name: String, group: String, logo: URL?, headers: [String: String])?
        for line in lines.dropFirst() {
            if line.uppercased().hasPrefix("#EXTINF:") {
                let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
                let attrs = parseAttributes(parts.first ?? "")
                let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : (attrs["tvg-name"] ?? "Unnamed")
                pending = (name, attrs["group-title"] ?? "Uncategorized", attrs["tvg-logo"].flatMap(URL.init(string:)), [:])
            } else if !line.hasPrefix("#"), let url = URL(string: line.trimmingCharacters(in: .whitespacesAndNewlines)), let item = pending {
                channels.append(TVChannel(id: stableID(source: source, name: item.name, url: url), name: item.name, group: item.group, logoURL: item.logo, streamURL: url, headers: item.headers))
                pending = nil
                if channels.count >= maxChannels { break }
            }
        }

        guard !channels.isEmpty else { throw SourceParseError.invalidInput("No channels found in M3U source.") }
        return SourceSnapshot(source: source, channels: channels, fetchedAt: .now, parserVersion: "m3u-1", warnings: [])
    }

    private func parseAttributes(_ line: String) -> [String: String] {
        let pattern = #"([A-Za-z0-9_-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).reduce(into: [:]) { result, match in
            guard let keyRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else { return }
            result[String(line[keyRange])] = String(line[valueRange])
        }
    }
}

struct TVBoxJSONAdapter: SourceAdapter {
    struct Config: Decodable {
        let lives: [Live]?
        struct Live: Decodable {
            let name: String?
            let type: Int?
            let url: String?
            let urls: [String]?
        }
    }

    func parse(data: Data, source: TVSource) throws -> SourceSnapshot {
        let config = try JSONDecoder().decode(Config.self, from: data)
        let lives = config.lives ?? []
        var channels: [TVChannel] = []
        for live in lives {
            guard let raw = live.url ?? live.urls?.first, let url = URL(string: raw) else { continue }
            channels.append(TVChannel(id: stableID(source: source, name: live.name ?? raw, url: url), name: live.name ?? raw, group: "Live", logoURL: nil, streamURL: url, headers: [:]))
        }
        guard !channels.isEmpty else { throw SourceParseError.unsupported("No static live channels found. Dynamic spiders/parsers are disabled in the MVP.") }
        return SourceSnapshot(source: source, channels: channels, fetchedAt: .now, parserVersion: "tvbox-json-1", warnings: [])
    }
}

private func stableID(source: TVSource, name: String, url: URL) -> String {
    "(source.id.uuidString)|(name)|(url.absoluteString)"
}
