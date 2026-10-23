import Foundation

/// 站点身份与显示名称分离，避免同名站点互相覆盖查询状态或混合筛选结果。
struct SearchProviderState {
    struct Provider: Identifiable {
        let id: String
        let name: String
        let sourceName: String
        var status: String
    }

    private var entries: [String: Provider] = [:]
    private var itemProviders: [String: String] = [:]

    /// 保留原始站名；所属订阅名仅用于同名站点的界面区分。
    mutating func catalog(_ sites: [TVBoxSite], source: TVSource) {
        for site in sites {
            let status = !site.searchable ? "站点已关闭搜索"
                : (site.api != nil || site.usesSpider ? "等待查询…" : "暂不支持此脚本站点")
            entries[site.id] = Provider(id: site.id, name: site.name, sourceName: source.name, status: status)
        }
    }

    /// 配置失败使用订阅身份，不会覆盖同名站点的状态。
    mutating func catalogFailed(_ source: TVSource) {
        let id = "source|\(source.id.uuidString)"
        entries[id] = Provider(id: id, name: source.name, sourceName: source.name,
                               status: "配置读取失败，请检查站源地址或网络。")
    }

    /// 每批结果记录真实来源 ID，显示名称相同也能独立筛选。
    mutating func result(_ result: Result<[TVMediaItem], Error>, site: TVBoxSite) {
        var entry = entries[site.id] ?? Provider(id: site.id, name: site.name, sourceName: site.name, status: "")
        switch result {
        case .success(let items):
            entry.status = items.isEmpty ? "无匹配影片" : "\(items.count) 条结果"
            for item in items { itemProviders[item.id] = site.id }
        case .failure(let error): entry.status = "查询失败：\(error.localizedDescription)"
        }
        entries[site.id] = entry
    }

    /// 公开目录也使用固定身份，避免与名为“公开检索”的配置站点冲突。
    mutating func fallback(_ items: [TVMediaItem]) {
        let items = items.filter { $0.siteKey == "public" }
        guard !items.isEmpty else { return }
        entries["public"] = Provider(id: "public", name: "公开检索", sourceName: "第三方目录", status: "\(items.count) 条结果（第三方目录）")
        for item in items { itemProviders[item.id] = "public" }
    }

    /// 排序与标签仅影响展示，筛选及查询状态始终使用 ID。
    var providers: [Provider] {
        entries.values.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.sourceName != $1.sourceName { return $0.sourceName < $1.sourceName }
            return $0.id < $1.id
        }
    }

    /// 同订阅名、同站名仍可通过稳定序号区分，不向用户展示内部摘要 ID。
    func label(for provider: Provider) -> String {
        let sameName = providers.filter { $0.name == provider.name }
        guard sameName.count > 1 else { return provider.name }
        let label = "\(provider.name) · \(provider.sourceName)"
        let duplicates = sameName.filter { $0.sourceName == provider.sourceName }
        guard duplicates.count > 1, let index = duplicates.firstIndex(where: { $0.id == provider.id }) else { return label }
        return "\(label)（\(index + 1)）"
    }

    /// 返回单个站点状态供当前筛选展示。
    func provider(id: String) -> Provider? { entries[id] }

    /// 以收到结果时记录的来源筛选，不从影片 ID 字符串反向解析协议。
    func providerID(for item: TVMediaItem) -> String? { itemProviders[item.id] }
}
