import Foundation

/// 使用有限的响应字节区分媒体与网页；URL 后缀和服务器 MIME 都可能不准确。
enum MediaProbe {
    enum Kind: Equatable {
        case media
        case webPage
        case unknown
    }

    /// 保留源站认证头并探测无后缀播放接口；未知响应由调用方保留原有路由策略。
    static func classify(url: URL, headers: [String: String] = [:], session: URLSession = .shared) async throws -> Kind {
        let (prefix, response) = try await readPrefix(url: url, headers: headers, count: 4096, session: session)
        return classify(prefix: prefix, contentType: response.value(forHTTPHeaderField: "Content-Type"))
    }

    /// 响应内容优先于 MIME：部分 CDN 用 video/mp4 返回 HTML 错误页，或把 MKV 标成 MP4。
    static func classify(prefix: Data, contentType: String?) -> Kind {
        let bytes = Array(prefix)
        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        let lower = text.lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.hasPrefix("<head") || lower.hasPrefix("<body") {
            return .webPage
        }
        if text.hasPrefix("#EXTM3U"), text.contains("#EXT-X-") { return .media }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return .media }
        if bytes.count >= 8, ["ftyp", "styp", "moov", "mdat"].contains(String(decoding: bytes[4..<8], as: UTF8.self)) { return .media }
        if bytes.count > 376, bytes[0] == 0x47, bytes[188] == 0x47, bytes[376] == 0x47 { return .media }
        let mime = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if mime == "text/html" || mime == "application/xhtml+xml" { return .webPage }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") || ["application/vnd.apple.mpegurl", "application/x-mpegurl"].contains(mime) { return .media }
        return .unknown
    }

    /// 即使服务端忽略 Range，也在达到上限后取消当前请求，不下载整部影片或关闭共享 session。
    static func readPrefix(url: URL, headers: [String: String], count: Int, offset: Int64 = 0, session: URLSession = .shared) async throws -> (Data, HTTPURLResponse) {
        guard ["http", "https"].contains(url.scheme?.lowercased()), count > 0, count <= 65_536, offset >= 0, offset <= Int64.max - Int64(count) else {
            throw SourceParseError.invalidInput("媒体探测参数无效。")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        playbackHTTPHeaders(overrides: headers).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceParseError.invalidInput("媒体服务返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)，请重新解析或切换线路。")
        }
        // 非零偏移必须由服务端确认，不能把忽略 Range 的文件头误当作尾部元数据。
        if offset > 0 || http.statusCode == 206 {
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard http.statusCode == 206, range.hasPrefix("bytes \(offset)-") else {
                throw SourceParseError.invalidInput("媒体服务未返回请求的字节范围。")
            }
        }
        var prefix = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            prefix.append(byte)
            if prefix.count >= count { break }
        }
        return (prefix, http)
    }
}
