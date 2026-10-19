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

/// TVBox 站点配置。站点 API 通常兼容 /api.php/provide/vod/?wd=关键词 查询约定。
struct TVBoxSite: Identifiable, Codable, Hashable {
    var id: String { key }
    let key: String
    let name: String
    let api: URL?
    let adapter: String?
    let searchable: Bool
    let quickSearch: Bool
    let spiderURL: URL?
    let spiderMD5: String?
    let spiderExt: String?

    var usesSpider: Bool { api == nil && adapter?.hasPrefix("csp_") == true }

    init(key: String, name: String, api: URL? = nil, adapter: String? = nil, searchable: Bool = true, quickSearch: Bool = true, spiderURL: URL? = nil, spiderMD5: String? = nil, spiderExt: String? = nil) {
        self.key = key; self.name = name; self.api = api; self.adapter = adapter
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.spiderURL = spiderURL
        self.spiderMD5 = spiderMD5
        self.spiderExt = spiderExt
    }

    private enum CodingKeys: String, CodingKey { case key, name, api, adapter, searchable, quickSearch, spiderURL, spiderMD5, spiderExt }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        api = try container.decodeIfPresent(URL.self, forKey: .api)
        adapter = try container.decodeIfPresent(String.self, forKey: .adapter)
        searchable = try container.decodeIfPresent(Bool.self, forKey: .searchable) ?? true
        quickSearch = try container.decodeIfPresent(Bool.self, forKey: .quickSearch) ?? true
        spiderURL = try container.decodeIfPresent(URL.self, forKey: .spiderURL)
        spiderMD5 = try container.decodeIfPresent(String.self, forKey: .spiderMD5)
        spiderExt = try container.decodeIfPresent(String.self, forKey: .spiderExt)
    }
}

/// 从站点搜索返回的影片条目，播放链接按站点原始格式保留，便于后续选择线路。
struct TVMediaItem: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var detailURL: URL?
    var posterURL: URL?
    var remark: String?
    var playSources: [TVPlaySource]
    /// 返回该影片的站点信息，便于用户在多个站源之间筛选线路。
    var sourceName: String
    var siteName: String
    var siteKey: String
    var spiderSite: TVBoxSite?
    var vodID: String?

    init(id: String, name: String, detailURL: URL? = nil, posterURL: URL? = nil,
         remark: String? = nil, playSources: [TVPlaySource] = [],
         sourceName: String = "公开检索", siteName: String = "公开检索", siteKey: String = "public", spiderSite: TVBoxSite? = nil, vodID: String? = nil) {
        self.id = id
        self.name = name
        self.detailURL = detailURL
        self.posterURL = posterURL
        self.remark = remark
        self.playSources = playSources
        self.sourceName = sourceName
        self.siteName = siteName
        self.siteKey = siteKey
        self.spiderSite = spiderSite
        self.vodID = vodID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, detailURL, posterURL, remark, playSources, sourceName, siteName, siteKey, spiderSite, vodID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        detailURL = try container.decodeIfPresent(URL.self, forKey: .detailURL)
        posterURL = try container.decodeIfPresent(URL.self, forKey: .posterURL)
        remark = try container.decodeIfPresent(String.self, forKey: .remark)
        playSources = try container.decodeIfPresent([TVPlaySource].self, forKey: .playSources) ?? []
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? "公开检索"
        siteName = try container.decodeIfPresent(String.self, forKey: .siteName) ?? sourceName
        siteKey = try container.decodeIfPresent(String.self, forKey: .siteKey) ?? "public"
        spiderSite = try container.decodeIfPresent(TVBoxSite.self, forKey: .spiderSite)
        vodID = try container.decodeIfPresent(String.self, forKey: .vodID)
    }
}

struct TVPlaySource: Codable, Hashable {
    var name: String
    var url: URL?
    /// Spider 的播放参数可能是加密字符串，必须先调用 playerContent。
    var playerID: String? = nil
    var flag: String? = nil

    /// CMS 和 Spider 共用线路分组；兼容旧缓存中只有名称前缀的记录。
    var routeName: String {
        if let flag, !flag.isEmpty { return flag }
        return name.components(separatedBy: " · ").count > 1
            ? name.components(separatedBy: " · ")[0] : "默认线路"
    }

    /// 只去掉明确的线路前缀，保留站点原始剧集名称。
    var episodeName: String {
        let prefix = "\(routeName) · "
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }
}

struct ResolvedMediaPlayback {
    let url: URL
    let headers: [String: String]
    let isDirect: Bool
}

/// 去掉同一播放地址（或同名同地址）重复项，保持源文件中的首次出现顺序。
func deduplicatedChannels(_ channels: [TVChannel]) -> [TVChannel] {
    var seen = Set<String>()
    return channels.filter { channel in
        let normalizedURL = channel.streamURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = normalizedURL.isEmpty ? "name|\(channel.name.lowercased())|group|\(channel.group.lowercased())" : normalizedURL
        return seen.insert(key).inserted
    }
}

struct SourceSnapshot: Codable, Hashable {
    var source: TVSource
    var channels: [TVChannel]
    var fetchedAt: Date
    var parserVersion: String
    var warnings: [String]
}
