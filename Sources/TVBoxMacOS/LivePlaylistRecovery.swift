import Foundation

/// 识别 TVBox 直播配置中的频道列表引用，避免将失效列表误交给 AVPlayer。
enum LivePlaylistRecovery {
    /// ghp.ci 包装的原始 GitHub 地址可按 URL 中明确指定的同一仓库回源，不替换用户频道来源。
    static func originalGitHubURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "ghp.ci",
              url.port == nil, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/raw.githubusercontent.com/") else { return nil }
        var original = URLComponents()
        original.scheme = "https"
        original.host = "raw.githubusercontent.com"
        original.percentEncodedPath = String(path.dropFirst("/raw.githubusercontent.com".count))
        original.percentEncodedQuery = components.percentEncodedQuery
        return original.url
    }

    /// 9978 是 Android TVBox 内部代理端口，macOS 没有该代理，不能作为独立直播频道。
    static func isAndroidProxy(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
            && url.port == 9978 && url.path == "/proxy"
    }

    /// 只迁移旧解析器留下的列表占位，不重新下载或清空已经展开的真实频道。
    static func needsStoredRepair(_ channel: TVChannel) -> Bool {
        channel.group == "Live" && (originalGitHubURL(channel.streamURL) != nil || isAndroidProxy(channel.streamURL))
    }

    /// TVBox TXT 使用“分组,#genre#”与“频道,URL”；不把 HTML 错误页误认为列表。
    static func isTextPlaylist(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { return false }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value == "#genre#" || value.hasPrefix("http://") || value.hasPrefix("https://")
        }
    }

    /// 有界解析文本频道列表，保留原源 ID、分组和列表请求头。
    static func parseText(_ data: Data, source: TVSource, headers: [String: String]) throws -> [TVChannel] {
        guard data.count <= 10 * 1024 * 1024, let text = String(data: data, encoding: .utf8), isTextPlaylist(data) else {
            throw SourceParseError.invalidInput("直播 TXT 频道列表格式无效。")
        }
        var group = "直播"
        var channels: [TVChannel] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == "#genre#" { group = name; continue }
            guard !name.isEmpty, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else { continue }
            channels.append(TVChannel(id: stableChannelID(source: source, name: name, url: url), name: name,
                                      group: group, logoURL: nil, streamURL: url, headers: headers))
            if channels.count >= 20_000 { break }
        }
        guard !channels.isEmpty else { throw SourceParseError.invalidInput("直播列表中没有可识别的频道。") }
        return deduplicatedChannels(channels)
    }
}
