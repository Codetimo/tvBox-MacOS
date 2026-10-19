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

        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("\u{feff}") }
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
                var headers: [String: String] = [:]
                if let userAgent = attrs["http-user-agent"] { headers["User-Agent"] = userAgent }
                if let referrer = attrs["http-referrer"] { headers["Referer"] = referrer }
                pending = (name, attrs["group-title"] ?? "Uncategorized", attrs["tvg-logo"].flatMap(URL.init(string:)), headers)
            } else if !line.hasPrefix("#"), let url = URL(string: String(line)), ["http", "https"].contains(url.scheme?.lowercased()), let item = pending {
                channels.append(TVChannel(id: stableID(source: source, name: item.name, url: url), name: item.name, group: item.group, logoURL: item.logo, streamURL: url, headers: item.headers))
                pending = nil
                if channels.count >= maxChannels { break }
            }
        }

        let uniqueChannels = deduplicatedChannels(channels)
        guard !uniqueChannels.isEmpty else { throw SourceParseError.invalidInput("No channels found in M3U source.") }
        return SourceSnapshot(source: source, channels: uniqueChannels, fetchedAt: .now, parserVersion: "m3u-2", warnings: [])
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
        let spider: String?
        let sites: [Site]?
        let lives: [Live]?
        struct Site: Decodable {
            let key: String?
            let name: String?
            let api: String?
            let type: Int?
            let searchable: IntOrBool?
            let quickSearch: IntOrBool?
            let ext: JSONExtension?
        }
        struct Live: Decodable {
            let name: String?
            let type: Int?
            let url: String?
            let urls: [String]?
            let ua: String?
        }
    }

    /// 解析 TVBox 的影视站点配置，供搜索界面按站点发起查询。
    func parseCatalog(data: Data) throws -> [TVBoxSite] {
        guard data.count <= 10 * 1024 * 1024 else { throw SourceParseError.invalidInput("TVBox JSON source exceeds the 10 MB safety limit.") }
        let config: Config
        do { config = try JSONDecoder().decode(Config.self, from: data) }
        catch { throw SourceParseError.invalidInput("TVBox JSON 格式无效：\(error.localizedDescription)") }
        let spiderParts = (config.spider ?? "").split(separator: ";", maxSplits: 2).map(String.init)
        let spiderURL = spiderParts.first.flatMap(URL.init(string:))
        let spiderMD5 = spiderParts.count >= 3 && spiderParts[1].lowercased() == "md5" ? spiderParts[2] : nil
        return (config.sites ?? []).compactMap { site in
            guard let key = site.key, let name = site.name else { return nil }
            let rawAPI = site.api ?? ""
            // type=3 和 JavaScript 地址需要脚本引擎，不能按 CMS HTTP 接口查询。
            let candidateURL = URL(string: rawAPI)
            let isScript = site.type == 3 || ["js", "mjs"].contains(candidateURL?.pathExtension.lowercased() ?? "")
            let api = candidateURL.flatMap { !isScript && ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
            let adapter = api == nil && !rawAPI.isEmpty ? rawAPI : nil
            return TVBoxSite(key: key, name: name, api: api, adapter: adapter, searchable: site.searchable?.value ?? true, quickSearch: site.quickSearch?.value ?? true, spiderURL: spiderURL, spiderMD5: spiderMD5, spiderExt: site.ext?.text)
        }
    }

    func parse(data: Data, source: TVSource) throws -> SourceSnapshot {
        guard data.count <= 10 * 1024 * 1024 else {
            throw SourceParseError.invalidInput("TVBox JSON source exceeds the 10 MB safety limit.")
        }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw SourceParseError.invalidInput("TVBox JSON 格式无效：\(error.localizedDescription)")
        }
        let lives = config.lives ?? []
        var channels: [TVChannel] = []
        for live in lives.prefix(20_000) {
            let urls = live.urls ?? (live.url.map { [$0] } ?? [])
            for raw in urls {
                guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else { continue }
                let name = live.name ?? raw
                var headers: [String: String] = [:]
                if let userAgent = live.ua, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
                channels.append(TVChannel(id: stableID(source: source, name: name, url: url), name: name, group: "Live", logoURL: nil, streamURL: url, headers: headers))
            }
        }
        let uniqueChannels = deduplicatedChannels(channels)
        guard !uniqueChannels.isEmpty || !(config.sites ?? []).isEmpty else {
            throw SourceParseError.unsupported("站源没有可识别的频道或影视站点。")
        }
        return SourceSnapshot(source: source, channels: uniqueChannels, fetchedAt: .now, parserVersion: "tvbox-json-2", warnings: [])
    }
}

/// TVBox 配置中既可能使用 0/1，也可能直接使用 true/false。
struct IntOrBool: Decodable {
    let value: Bool
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool; return }
        if let int = try? container.decode(Int.self) { value = int != 0; return }
        value = false
    }
}

/// 解析主流 CMS VOD API 的搜索响应。字段缺失时保留条目，避免单个站点字段差异导致整个搜索失败。
enum TVBoxSearchParser {
    /// 计算搜索结果与关键词的匹配度，分值越高越靠前。保留原始结果顺序作为同分时的稳定排序依据。
    static func searchRelevanceScore(name: String, keyword: String) -> Int {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty, !normalizedKeyword.isEmpty else { return 0 }
        if normalizedName == normalizedKeyword { return 1_000 }
        if normalizedName.hasPrefix(normalizedKeyword) { return 800 }
        if normalizedName.contains(normalizedKeyword) { return 600 }
        let terms = normalizedKeyword.split { $0.isWhitespace || "，,。.!！？?、".contains($0) }
        let matchedTerms = terms.filter { normalizedName.contains($0) }.count
        return matchedTerms > 0 ? 300 + matchedTerms * 20 : 0
    }

    static func makeSearchURL(site: TVBoxSite, keyword: String) -> URL? {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let api = site.api else { return nil }
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { ["wd", "ac", "ids"].contains($0.name.lowercased()) }
        items.append(URLQueryItem(name: "ac", value: "detail"))
        items.append(URLQueryItem(name: "wd", value: keyword.trimmingCharacters(in: .whitespacesAndNewlines)))
        components?.queryItems = items
        return components?.url
    }

    /// 为只返回摘要的 CMS 搜索结果构造标准详情请求地址。
    static func makeDetailURL(site: TVBoxSite, id: String) -> URL? {
        guard let api = site.api, !id.isEmpty else { return nil }
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { ["wd", "ac", "ids"].contains($0.name.lowercased()) }
        items.append(URLQueryItem(name: "ac", value: "detail"))
        items.append(URLQueryItem(name: "ids", value: id))
        components?.queryItems = items
        return components?.url
    }

    /// 解析 CMS/Spider 返回的影片列表。部分 Spider 会把标准响应包在 data 中，
    /// 也有实现直接返回数组；这里先规整为标准 {"list": [...]} 结构。
    static func parse(data: Data, site: TVBoxSite, fallbackName: String? = nil) throws -> [TVMediaItem] {
        struct Response: Decodable { let list: [Item]? }
        struct Item: Decodable {
            let vodID: String?
            let name: String?
            let pic: String?
            let remark: String?
            let playURL: String?
            let playFrom: String?
            enum CodingKeys: String, CodingKey {
                case vodID = "vod_id", name = "vod_name", pic = "vod_pic", remark = "vod_remarks", playURL = "vod_play_url", playFrom = "vod_play_from"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                vodID = try container.decodeFlexibleString(forKey: .vodID)
                name = try container.decodeFlexibleString(forKey: .name)
                pic = try container.decodeFlexibleString(forKey: .pic)
                remark = try container.decodeFlexibleString(forKey: .remark)
                playURL = try container.decodeFlexibleString(forKey: .playURL)
                playFrom = try container.decodeFlexibleString(forKey: .playFrom)
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: normalizedListData(data: data))
        return (response.list ?? []).compactMap { item in
            guard let name = (item.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? item.name : fallbackName),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // $$$ 分隔播放线路，# 分隔同一线路中的剧集，不能把它们一起拆成 URL。
            let routeNames = (item.playFrom ?? "").components(separatedBy: "$$$")
            let playSources = (item.playURL ?? "").components(separatedBy: "$$$").enumerated().flatMap { routeIndex, route in
                route.split(separator: "#").compactMap { raw -> TVPlaySource? in
                    let pieces = raw.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    let rawURL = (pieces.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawURL.isEmpty else { return nil }
                    let url = URL(string: rawURL).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
                    guard site.usesSpider || url != nil else { return nil }
                    let episodeName = pieces.count > 1 && !pieces[0].isEmpty ? pieces[0] : "播放"
                    let routeName = routeIndex < routeNames.count ? routeNames[routeIndex].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    return TVPlaySource(name: routeName.isEmpty ? episodeName : "\(routeName) · \(episodeName)", url: site.usesSpider ? nil : url, playerID: site.usesSpider ? rawURL : nil, flag: site.usesSpider ? routeName : nil)
                }
            }
            let vodID = item.vodID ?? name
            return TVMediaItem(id: "\(site.api?.absoluteString ?? site.spiderURL?.absoluteString ?? site.adapter ?? "unknown")|\(site.key)|\(vodID)", name: name,
                               detailURL: TVBoxSearchParser.makeDetailURL(site: site, id: item.vodID ?? ""),
                               posterURL: item.pic.flatMap(URL.init(string:)), remark: item.remark,
                               playSources: playSources,
                               sourceName: site.name, siteName: site.name, siteKey: site.key, spiderSite: site.usesSpider ? site : nil, vodID: item.vodID)
        }
    }

    /// 将不同 Spider 的列表包装规整成统一的 CMS 响应，避免详情因外层 data/数组包装而被判为空。
    private static func normalizedListData(data: Data) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: data, options: [])
        let list = extractList(from: root)
        guard let list, JSONSerialization.isValidJSONObject(["list": list]) else {
            throw SourceParseError.invalidInput("站点返回的影片详情格式无法识别。")
        }
        return try JSONSerialization.data(withJSONObject: ["list": list], options: [])
    }

    /// 递归识别 data/result/payload 等常见外层包装。
    private static func extractList(from value: Any) -> Any? {
        if let array = value as? [[String: Any]] { return array }
        guard let object = value as? [String: Any] else { return nil }
        if let list = object["list"] { return list }
        for key in ["data", "result", "payload"] {
            if let nested = object[key], let list = extractList(from: nested) { return list }
        }
        return nil
    }

    /// 对 Spider 返回的 ID 做宽松匹配，兼容 URL 编码和大小写差异。
    static func normalizedIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.removingPercentEncoding ?? trimmed).lowercased()
    }

    /// 按详情请求的 ID/名称选择结果。详情接口常会省略 vod_id，或返回展示名而不是搜索名。
    static func matchDetail(_ details: [TVMediaItem], requestedID: String, requestedName: String) -> TVMediaItem? {
        let normalizedID = normalizedIdentifier(requestedID)
        if let exact = details.first(where: { detail in
            guard let detailID = detail.vodID else { return false }
            return normalizedIdentifier(detailID) == normalizedID
        }) { return exact }
        let normalizedName = normalizedTitle(requestedName)
        if let byName = details.first(where: { normalizedTitle($0.name) == normalizedName }) { return byName }
        // ids 查询应只返回所请求影片；即使站点省略 vod_id/名称，也保留唯一结果。
        return details.count == 1 ? details[0] : nil
    }

    private static func normalizedTitle(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 { result = result.removingPercentEncoding ?? result }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).lowercased()
    }

    /// 解析 360 搜索接口，作为未携带可直连 API 的 Spider 站源的搜索后备。
    static func parse360(data: Data) throws -> [TVMediaItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let longData = payload["longData"] as? [String: Any],
              let rows = longData["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["titleTxt"] as? String, !name.isEmpty else { return nil }
            let id = row["en_id"] as? String ?? UUID().uuidString
            let poster = (row["cover"] as? String).flatMap(URL.init(string:))
            let detail = (row["url"] as? String).flatMap(URL.init(string:))
            let remark = [row["year"] as? String, row["description"] as? String].compactMap { $0 }.first
            let links = (row["playlinks"] as? [String: String] ?? [:]).compactMap { name, raw in
                URL(string: raw).map { TVPlaySource(name: name, url: $0) }
            }.sorted { $0.name < $1.name }
            return TVMediaItem(id: "360:\(id)", name: name, detailURL: detail, posterURL: poster, remark: remark,
                               playSources: links, sourceName: "公开检索", siteName: "公开检索", siteKey: "public")
        }
    }
}

private extension KeyedDecodingContainer {
    /// CMS 接口经常把 vod_id 在不同站点返回为字符串或整数，统一转换为字符串。
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

private func stableID(source: TVSource, name: String, url: URL) -> String {
    "\(source.id.uuidString)|\(name)|\(url.absoluteString)"
}

/// ext 可以是字符串或 JSON 对象；传给 Spider.init 时保持它的原始语义。
indirect enum JSONExtension: Codable {
    case string(String), object([String: JSONExtension]), array([JSONExtension]), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String: JSONExtension].self) { self = .object(object) }
        else { self = .array(try value.decode([JSONExtension].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .number(let number): try value.encode(number)
        case .bool(let boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }

    var text: String {
        if case .string(let value) = self { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
