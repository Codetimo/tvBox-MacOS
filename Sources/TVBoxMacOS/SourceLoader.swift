import Foundation

enum SourceLoaderError: LocalizedError {
    case unsupportedURL
    case emptyResponse
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: return "请输入 http 或 https 地址。"
        case .emptyResponse: return "源返回内容为空。"
        case .unsupportedFormat: return "暂时只支持 M3U 和静态 TVBox JSON。"
        }
    }
}

struct SourceLoader {
    var session: URLSession = .shared

    /// 站源目录在启动预热和首次搜索之间会被重复读取。进程内短期缓存避免每次搜索重新下载同一份 JSON。
    /// 这和 Java 里的带过期时间的本地 Cache 类似：应用重启自动清空，重新导入源时显式失效。
    private static let catalogCache = CatalogCache()
    private static let catalogCacheTTL: TimeInterval = 5 * 60

    /// 清除指定地址的目录缓存，源被用户重新导入时调用。
    static func invalidateCatalog(url: URL) {
        catalogCache.invalidate(url: url)
    }

    /// 加载 TVBox JSON 中的影视站点配置，供搜索界面展示可搜索站点。
    func loadCatalog(url: URL) async throws -> [TVBoxSite] {
        if let cached = Self.catalogCache.value(url: url, maxAge: Self.catalogCacheTTL) {
            return cached
        }
        if url.isFileURL {
            let catalog = try TVBoxJSONAdapter().parseCatalog(data: Data(contentsOf: url, options: [.mappedIfSafe]))
            Self.catalogCache.store(catalog, url: url)
            return catalog
        }
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { throw SourceLoaderError.unsupportedURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        let catalog = try TVBoxJSONAdapter().parseCatalog(data: data)
        Self.catalogCache.store(catalog, url: url)
        return catalog
    }

    /// 调用 CMS 搜索接口并解析为统一影片条目。
    func search(site: TVBoxSite, keyword: String, spiderBaseURL: URL? = nil, spiderToken: String? = nil) async throws -> [TVMediaItem] {
        if site.api == nil {
            guard site.usesSpider else { return [] }
            return try await searchSpider(site: site, keyword: keyword, baseURL: spiderBaseURL, token: spiderToken)
        }
        guard let url = TVBoxSearchParser.makeSearchURL(site: site, keyword: keyword) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // 很多 CMS 会拒绝 URLSession 的默认身份，搜索请求使用浏览器兼容的请求头。
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        let results = try TVBoxSearchParser.parse(data: data, site: site)
        // 部分 CMS 的搜索接口只返回影片摘要，播放地址需要再调用 ac=detail。
        return await enrichPlaybackSources(results, site: site)
    }

    /// Spider 搜索仅加载摘要，用户选择影片时再请求详情，避免每次搜索拉取大量线路。
    private func searchSpider(site: TVBoxSite, keyword: String, baseURL: URL?, token: String?) async throws -> [TVMediaItem] {
        // quickSearch 只声明搜索模式，不代表 Spider 包与宿主兼容。
        let data = try await spiderRequest("search", site: site, parameters: ["keyword": keyword, "quick": true], baseURL: baseURL, token: token)
        return try TVBoxSearchParser.parse(data: data, site: site)
    }

    /// 使用原始 vod_id 加载当前影片的线路，拒绝误匹配到另一部影片。
    func loadSpiderDetail(item: TVMediaItem, baseURL: URL?, token: String?) async throws -> TVMediaItem {
        guard let site = item.spiderSite, let id = item.vodID, !id.isEmpty else {
            throw SourceParseError.invalidInput("该影片缺少 Spider 详情参数。")
        }
        let data = try await spiderRequest("detail", site: site, parameters: ["ids": [id]], baseURL: baseURL, token: token)
        // 详情接口有些实现会省略 vod_id，或把 ID 编码/改变大小写；单条请求时
        // 可用原影片名称做二次校验，避免把正确详情误判成“站点未返回”。
        let details = try TVBoxSearchParser.parse(data: data, site: site, fallbackName: item.name)
        guard let detail = TVBoxSearchParser.matchDetail(details, requestedID: id, requestedName: item.name) else {
            throw SourceParseError.invalidInput("站点未返回所选影片的详情。")
        }
        guard !detail.playSources.isEmpty else { throw SourceParseError.invalidInput("站点未返回可播放线路。") }
        // 保留搜索条目的稳定 ID 和站点信息，避免 Spider 详情缺少 vod_id 时
        // 写回列表后无法再次定位或继续调用播放接口。
        return TVMediaItem(id: item.id, name: detail.name, detailURL: item.detailURL ?? detail.detailURL,
                           posterURL: detail.posterURL ?? item.posterURL, remark: detail.remark ?? item.remark,
                           playSources: detail.playSources, sourceName: item.sourceName, siteName: item.siteName,
                           siteKey: item.siteKey, spiderSite: site, vodID: item.vodID)
    }

    /// 先让 Spider 解析播放 ID；只有 parse=0 的 HTTP 地址可直接交给 AVPlayer。
    func resolvePlayback(item: TVMediaItem, source: TVPlaySource, baseURL: URL?, token: String?) async throws -> ResolvedMediaPlayback {
        if let site = item.spiderSite {
            guard let id = source.playerID, !id.isEmpty else { throw SourceParseError.invalidInput("缺少 Spider 播放 ID。") }
            let data = try await spiderRequest("player", site: site, parameters: ["id": id, "flag": source.flag ?? "", "vipFlags": []], baseURL: baseURL, token: token)
            return try Self.parseSpiderPlayback(data: data)
        }
        guard let url = source.url, ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw SourceParseError.invalidInput("站点没有提供可用的 HTTP 播放地址。")
        }
        let isDirect = ["m3u8", "mp4", "mov", "ts", "mkv"].contains(url.pathExtension.lowercased())
        return ResolvedMediaPlayback(url: url, headers: [:], isDirect: isDirect)
    }

    /// 保留站点返回的请求头，明确拒绝需 WebView 嗅探或额外解析器的播放协议。
    static func parseSpiderPlayback(data: Data) throws -> ResolvedMediaPlayback {
        let decoded: Any
        if let json = try? JSONSerialization.jsonObject(with: data) {
            decoded = json
        } else if let raw = String(data: data, encoding: .utf8), let url = validHTTPURL(raw) {
            return ResolvedMediaPlayback(url: url, headers: [:], isDirect: true)
        } else {
            throw SourceParseError.invalidInput("Spider 播放响应不是 JSON 对象。")
        }
        // 少数桥接实现会再包一层 data，或直接返回 JSON 字符串/播放地址。
        let object: [String: Any]
        if let direct = decoded as? [String: Any] {
            object = unwrapPlaybackObject(direct)
        } else if let values = decoded as? [Any], let direct = values.compactMap({ $0 as? [String: Any] }).first {
            object = unwrapPlaybackObject(direct)
        } else if let rawURL = decoded as? String, let url = validHTTPURL(rawURL) {
            return ResolvedMediaPlayback(url: url, headers: [:], isDirect: true)
        } else {
            throw SourceParseError.invalidInput("Spider 播放响应不是 JSON 对象。")
        }
        let values = object.reduce(into: [String: Any]()) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        if let message = flexibleString(values["msg"] ?? values["message"]), !message.isEmpty,
           flexibleString(values["url"] ?? values["src"] ?? values["source"]).flatMap(validHTTPURL) == nil {
            throw SpiderPlaybackFailure.from(message: message)
        }
        let parse = values["parse"].map { String(describing: $0).lowercased() } ?? "0"
        let jx = values["jx"].map { String(describing: $0).lowercased() } ?? "0"
        guard ["0", "false"].contains(parse), ["0", "false"].contains(jx) else {
            throw SourceParseError.unsupported("这条线路需要网页嗅探或外部解析器（parse=\(parse)，jx=\(jx)），当前暂不支持，请选择其他线路。")
        }
        let prefix = flexibleString(values["playurl"] ?? values["play_url"]) ?? ""
        guard prefix.isEmpty else { throw SourceParseError.unsupported("这条线路需要外部 playUrl 解析器，请选择其他线路。") }
        guard let raw = flexibleString(values["url"] ?? values["src"] ?? values["source"]), let url = validHTTPURL(raw) else {
            throw SourceParseError.invalidInput("Spider 未解析出可用的 HTTP 播放地址。")
        }
        var rawHeaders = values["header"] ?? values["headers"]
        if let encoded = rawHeaders as? String, !encoded.isEmpty {
            if let decoded = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) {
                rawHeaders = decoded
            } else {
                // 少数 Spider 用 key=value 或 key$value 文本传递请求头。
                var parsed: [String: String] = [:]
                for part in encoded.split(whereSeparator: { $0 == "&" || $0 == ";" || $0 == "\n" }) {
                    let pieces = part.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == "$" }).map(String.init)
                    if pieces.count == 2 { parsed[pieces[0].trimmingCharacters(in: .whitespaces)] = pieces[1].trimmingCharacters(in: .whitespaces) }
                }
                rawHeaders = parsed
            }
        }
        var headers: [String: String] = [:]
        if let values = rawHeaders as? [String: Any] {
            for (key, value) in values {
                guard let text = value as? String, !key.contains("\r"), !key.contains("\n"), !text.contains("\r"), !text.contains("\n") else { continue }
                headers[key] = text
            }
        }
        return ResolvedMediaPlayback(url: url, headers: headers, isDirect: true)
    }

    /// 将不同 Spider 返回的字符串/嵌套 URL 统一为可播放的 HTTP 地址。
    private static func flexibleString(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }
        if let nested = value as? [String: Any] {
            let values = nested.reduce(into: [String: Any]()) { result, entry in result[entry.key.lowercased()] = entry.value }
            return flexibleString(values["url"] ?? values["src"] ?? values["playurl"])
        }
        if let values = value as? [Any] { return values.lazy.compactMap { flexibleString($0) }.first }
        return nil
    }

    /// 递归展开 Spider 常见的 data/result/payload 包装，同时保留外层 parse/jx 等控制字段。
    private static func unwrapPlaybackObject(_ object: [String: Any], depth: Int = 0) -> [String: Any] {
        guard depth < 5 else { return object }
        let normalized = object.reduce(into: [String: Any]()) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        let wrapper = normalized["data"] ?? normalized["result"] ?? normalized["payload"]
        let nested: [String: Any]?
        if let dictionary = wrapper as? [String: Any] {
            nested = unwrapPlaybackObject(dictionary, depth: depth + 1)
        } else if let encoded = wrapper as? String,
                  let data = encoded.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            nested = unwrapPlaybackObject(dictionary, depth: depth + 1)
        } else if let array = wrapper as? [Any],
                  let dictionary = array.compactMap({ $0 as? [String: Any] }).first {
            nested = unwrapPlaybackObject(dictionary, depth: depth + 1)
        } else {
            nested = nil
        }
        guard let nested else { return normalized }
        return normalized.merging(nested) { _, nestedValue in nestedValue }
    }

    /// 仅接受带主机的 HTTP(S) 地址，避免把 Spider 的相对路径交给播放器。
    private static func validHTTPURL(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        // 只解码整体编码的 URL；有效 URL 内的 %26/%2B 等属于签名或嵌套地址。
        if !value.lowercased().hasPrefix("http://"), !value.lowercased().hasPrefix("https://") {
            value = value.removingPercentEncoding ?? value
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Immediately apply saved credentials or explicit logout to the running package.
    func synchronizePanCookies(site: TVBoxSite, baseURL: URL?, token: String?) async throws {
        let data = try await spiderRequest("pan-cookies", site: site, parameters: [:], baseURL: baseURL, token: token)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["synced"] as? Bool == true else {
            throw SourceParseError.unsupported("该站源不支持自动同步网盘配置。")
        }
    }

    /// 所有调用显式携带包、类和 ext，使多站源切换不依赖服务端上次请求状态。
    private func spiderRequest(_ endpoint: String, site: TVBoxSite, parameters: [String: Any], baseURL: URL?, token: String?) async throws -> Data {
        guard let baseURL, let token, !token.isEmpty else { throw SourceParseError.unsupported("本地 Spider 服务尚未就绪。") }
        guard site.usesSpider, let adapter = site.adapter, let package = site.spiderURL else {
            throw SourceParseError.unsupported("此站点未提供可用的 csp Spider 包。")
        }
        var payload = parameters
        payload["spider"] = package.absoluteString
        payload["md5"] = site.spiderMD5 ?? ""
        payload["spiderClass"] = adapter
        let snapshot = try PanCookieStore.shared.bridgeSnapshot()
        let cookies = snapshot.cookies
        payload["pan_cookie_version"] = snapshot.version
        payload["pan_cookies"] = cookies
        let spiderExt = PanCookieStore.spiderExtension(
            base: site.spiderExt,
            quark: cookies["quark"],
            baidu: cookies["baidu"]
        )
        payload["spider_ext"] = spiderExt
        payload["ext"] = spiderExt
        var request = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-TVBox-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
            throw SourceParseError.invalidInput("与本地 Spider 服务的连接中断，服务恢复后请重试；这不代表资源站或互联网断网。")
        } catch let error as URLError where error.code == .timedOut {
            throw SourceParseError.invalidInput("本地 Spider 查询超时，可能是站点响应慢或引擎繁忙，请稍后重试。")
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceParseError.invalidInput("本地 Spider 服务返回了无效响应。")
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode, envelope["ok"] as? Bool == true else {
            throw SourceParseError.invalidInput("Spider：\(envelope["error"] as? String ?? "服务调用失败")")
        }
        if let text = envelope["data"] as? String { return Data(text.utf8) }
        guard let payload = envelope["data"], JSONSerialization.isValidJSONObject(payload) else {
            throw SourceParseError.invalidInput("Spider 没有返回有效数据。")
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// 每批最多同时请求 4 条详情，并按原搜索顺序写回；失败或 ID 不匹配时保留摘要。
    private func enrichPlaybackSources(_ results: [TVMediaItem], site: TVBoxSite) async -> [TVMediaItem] {
        var enriched = results
        let pending = results.indices.filter { results[$0].playSources.isEmpty && results[$0].detailURL != nil }
        for batchStart in stride(from: 0, to: pending.count, by: 4) {
            let batch = pending[batchStart..<min(batchStart + 4, pending.count)]
            await withTaskGroup(of: (Int, [TVPlaySource]?).self) { group in
                for index in batch {
                    let item = results[index]
                    group.addTask {
                        guard let detailURL = item.detailURL else { return (index, nil) }
                        var request = URLRequest(url: detailURL)
                        request.timeoutInterval = 12
                        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
                        do {
                            let (detailData, response) = try await self.session.data(for: request)
                            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return (index, nil) }
                            let detail = try TVBoxSearchParser.parse(data: detailData, site: site)
                            guard let matched = detail.first(where: { $0.id == item.id }), !matched.playSources.isEmpty else { return (index, nil) }
                            return (index, matched.playSources)
                        } catch { return (index, nil) }
                    }
                }
                for await (index, sources) in group {
                    if let sources { enriched[index].playSources = sources }
                }
            }
        }
        return enriched
    }

    /// 搜索公开影片目录，供 Spider-only 配置也能按片名得到影片条目。
    func searchFallback(keyword: String) async throws -> [TVMediaItem] {
        var components = URLComponents(string: "https://api.so.360kan.com/index")!
        components.queryItems = [URLQueryItem(name: "kw", value: keyword)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try TVBoxSearchParser.parse360(data: data)
    }

    func load(url: URL) async throws -> SourceSnapshot {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw SourceLoaderError.unsupportedURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { throw SourceLoaderError.emptyResponse }

        let snapshot = try parse(data: data, location: url, name: url.host ?? "Remote source")
        guard snapshot.source.kind == .tvboxJSON else { return snapshot }
        return await expandLivePlaylists(in: snapshot)
    }

    /// 读取本地 M3U/JSON 文件，方便个人源不必上传到公网。
    func load(fileURL: URL) throws -> SourceSnapshot {
        guard fileURL.isFileURL else { throw SourceLoaderError.unsupportedURL }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw SourceLoaderError.emptyResponse }
        return try parse(data: data, location: fileURL, name: fileURL.deletingPathExtension().lastPathComponent)
    }

    private func parse(data: Data, location: URL, name: String) throws -> SourceSnapshot {
        let firstNonWhitespace = data.drop { $0 == 0xEF || $0 == 0xBB || $0 == 0xBF || $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }.first
        let extensionName = location.pathExtension.lowercased()
        let sourceKind: SourceKind = extensionName == "m3u" || extensionName == "m3u8" || firstNonWhitespace == 0x23 ? .m3u : .tvboxJSON
        let source = TVSource(name: name, location: location, kind: sourceKind)
        switch sourceKind {
        case .m3u: return try M3UAdapter().parse(data: data, source: source)
        case .tvboxJSON: return try TVBoxJSONAdapter().parse(data: data, source: source)
        }
    }

    /// TVBox 的 lives.url 通常还是一个 M3U 播放列表，先展开它再交给播放器，避免把播放列表误当成视频地址。
    private func expandLivePlaylists(in snapshot: SourceSnapshot) async -> SourceSnapshot {
        var expanded: [TVChannel] = []
        var warnings = snapshot.warnings
        for channel in snapshot.channels {
            do {
                var request = URLRequest(url: channel.streamURL)
                request.timeoutInterval = 15
                for (key, value) in channel.headers { request.setValue(value, forHTTPHeaderField: key) }
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true else {
                    throw URLError(.badServerResponse)
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("#EXTM3U") else {
                    expanded.append(channel)
                    continue
                }
                let nested = try M3UAdapter().parse(data: data, source: snapshot.source)
                expanded.append(contentsOf: nested.channels)
            } catch {
                // 单个直播组不可用时保留原地址，用户仍可尝试直接播放，并在界面提示。
                expanded.append(channel)
                warnings.append("直播源 \(channel.name) 展开失败：\(error.localizedDescription)")
            }
        }
        return SourceSnapshot(source: snapshot.source, channels: deduplicatedChannels(expanded), fetchedAt: snapshot.fetchedAt, parserVersion: "tvbox-json-2", warnings: warnings)
    }
}

private final class CatalogCache {
    private struct Entry {
        let catalog: [TVBoxSite]
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func value(url: URL, maxAge: TimeInterval) -> [TVBoxSite]? {
        let key = url.absoluteString
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) <= maxAge else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.catalog
    }

    func store(_ catalog: [TVBoxSite], url: URL) {
        lock.lock()
        entries[url.absoluteString] = Entry(catalog: catalog, storedAt: .now)
        lock.unlock()
    }

    func invalidate(url: URL) {
        lock.lock()
        entries.removeValue(forKey: url.absoluteString)
        lock.unlock()
    }
}
