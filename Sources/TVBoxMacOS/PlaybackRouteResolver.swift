import Foundation

enum SpiderPlaybackFailure: LocalizedError {
    case insufficientStorage(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .insufficientStorage(let message): return "\(message)。可切换其他网盘线路，或在对应网盘释放空间后重试。"
        case .rejected(let message): return "站点无法提供播放地址：\(message)"
        }
    }

    /// 保留站点真实失败原因，不把容量、失效链接等错误全部归类为授权问题。
    static func from(message: String) -> SpiderPlaybackFailure {
        if message.contains("空间不足") || message.contains("容量不足") {
            return .insufficientStorage(message)
        }
        return .rejected(message)
    }
}

struct PlaybackRouteSelection {
    let source: TVPlaySource
    let playback: ResolvedMediaPlayback
    let notice: String?
}

enum PlaybackRouteResolver {
    /// 空间不足时最多尝试两条其他线路；多集内容只匹配明确相同的剧集名。
    static func resolve(source: TVPlaySource, sources: [TVPlaySource],
                        using resolve: (TVPlaySource) async throws -> ResolvedMediaPlayback) async throws -> PlaybackRouteSelection {
        try Task.checkCancellation()
        do {
            let playback = try await resolve(source)
            try Task.checkCancellation()
            return PlaybackRouteSelection(source: source, playback: playback, notice: nil)
        } catch let failure as SpiderPlaybackFailure {
            guard case .insufficientStorage = failure else { throw failure }
            let alternatives = alternatives(for: source, in: sources)
            for candidate in alternatives.prefix(2) {
                try Task.checkCancellation()
                do {
                    let playback = try await resolve(candidate)
                    try Task.checkCancellation()
                    return PlaybackRouteSelection(source: candidate, playback: playback,
                        notice: "\(source.flag ?? "原线路")空间不足，已切换到\(candidate.flag ?? candidate.name)")
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            try Task.checkCancellation()
            if alternatives.isEmpty { throw failure }
            throw SourceParseError.invalidInput("\(failure.localizedDescription) 自动尝试的备用线路也未能解析，请手动选择其他线路。")
        }
    }

    /// 同一影片每条线路都只有一个文件时允许名称不同；否则必须严格匹配集名。
    static func alternatives(for source: TVPlaySource, in sources: [TVPlaySource]) -> [TVPlaySource] {
        guard let flag = source.flag, !flag.isEmpty else { return [] }
        let grouped = Dictionary(grouping: sources, by: { $0.flag ?? "" })
        let singleFile = !grouped.isEmpty && grouped.values.allSatisfy { $0.count == 1 }
            && sources.allSatisfy { seasonEpisode($0.episodeName) == nil }
        let episode = episodeName(source)
        var seenFlags: Set<String> = [flag]
        return sources.filter { candidate in
            guard let other = candidate.flag, !other.isEmpty, other != flag,
                  singleFile || (!episode.isEmpty && episode != "播放" && matchesEpisode(source, candidate)) else { return false }
            // 夸克不同画质仍使用同一份网盘容量，优先绕过整个夸克提供方。
            if flag.contains("夸克") || flag.lowercased().contains("quark") {
                if other.contains("夸克") || other.lowercased().contains("quark") { return false }
            }
            // 同线路若有重复集号（例如正片与花絮），不自动决定，交给用户选集。
            guard singleFile || grouped[other]?.filter({ matchesEpisode(source, $0) }).count == 1 else { return false }
            return seenFlags.insert(other).inserted
        }
    }

    /// 文件名前缀和大小可以不同；只有明确的季、集编号相同时才自动换源。
    static func matchesEpisode(_ lhs: TVPlaySource, _ rhs: TVPlaySource) -> Bool {
        if lhs.episodeName == rhs.episodeName { return true }
        guard let left = seasonEpisode(lhs.episodeName), let right = seasonEpisode(rhs.episodeName) else { return false }
        return left == right
    }

    /// 识别 S06E03 这类完整季集标识；多集合集或花絮不参与自动匹配。
    private static func seasonEpisode(_ name: String) -> String? {
        guard !["花絮", "预告", "特辑", "番外", "trailer", "special", "合集"].contains(where: { name.lowercased().contains($0) }),
              let regex = try? NSRegularExpression(pattern: #"(?i)(?<![a-z0-9])S(\d{1,2})E(\d{1,3})(?![a-z0-9]|[-~–]\d)"#) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        let matches = regex.matches(in: name, range: range)
        guard matches.count == 1, let match = matches.first,
              let seasonRange = Range(match.range(at: 1), in: name),
              let episodeRange = Range(match.range(at: 2), in: name),
              let season = Int(name[seasonRange]), let episode = Int(name[episodeRange]) else { return nil }
        return "\(season):\(episode)"
    }

    /// 复用目录模型的剧集名称，兼容 CMS 与 Spider。
    private static func episodeName(_ source: TVPlaySource) -> String { source.episodeName }
}
