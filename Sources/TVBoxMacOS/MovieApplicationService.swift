import Combine
import Foundation

/// 站源业务入口统一保证 Spider 生命周期，View 只处理选择、导航和展示状态。
@MainActor
struct MovieApplicationService {
    let spider: SpiderService
    var loader = SourceLoader()

    /// 搜索只取摘要；详情在用户打开影片后刷新。
    func search(site: TVBoxSite, keyword: String) async throws -> [TVMediaItem] {
        if site.usesSpider { try await spider.ensureReady() }
        try Task.checkCancellation()
        return try await loader.search(site: site, keyword: keyword,
            spiderBaseURL: spider.baseURL, spiderToken: spider.token, enrichDetails: false)
    }

    /// 重新请求影片详情，调用方可在失败时继续保留旧快照。
    func detail(for item: TVMediaItem) async throws -> TVMediaItem {
        if item.spiderSite != nil {
            try await spider.ensureReady()
            return try await loader.loadSpiderDetail(item: item, baseURL: spider.baseURL, token: spider.token)
        }
        return try await loader.loadCMSDetail(item: item)
    }

    /// 地址会过期，按线路和剧集精确匹配；出现歧义时让用户重选，避免误播其他剧集。
    static func refreshedSource(_ source: TVPlaySource, in item: TVMediaItem) -> TVPlaySource? {
        let matches = item.playSources.filter { $0.routeName == source.routeName && $0.episodeName == source.episodeName }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 冷启动收藏播放也会启动桥接服务，并在解析后建立本机媒体转发。
    func resolve(item: TVMediaItem, source: TVPlaySource) async throws -> ResolvedMediaPlayback {
        if item.spiderSite != nil { try await spider.ensureReady() }
        let resolved = try await loader.resolvePlayback(item: item, source: source, baseURL: spider.baseURL, token: spider.token)
        let url = item.spiderSite == nil ? resolved.url : try await spider.preparePlaybackURL(resolved.url)
        try Task.checkCancellation()
        return ResolvedMediaPlayback(url: url, headers: resolved.headers, isDirect: resolved.isDirect)
    }
}

/// 详情快照只用于快速展示；每次打开或选择另一个站点都刷新，失败时旧线路仍可操作。
@MainActor
final class MovieDetailModel: ObservableObject {
    @Published private(set) var item: TVMediaItem
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var revision = UUID()

    /// 使用缓存的影片作为初始展示内容，不将其当成永不过期的详情。
    init(item: TVMediaItem) { self.item = item }

    /// 切换站点时使旧请求失效，避免迟到响应覆盖新选择。
    func select(_ item: TVMediaItem) {
        revision = UUID()
        self.item = item
        isLoading = false
        errorMessage = nil
    }

    /// 刷新有详情入口的影片；成功替换快照，失败保留已有线路供用户重试播放。
    func refresh(using load: (TVMediaItem) async throws -> TVMediaItem) async {
        guard !isLoading, item.spiderSite != nil || (item.siteKey != "public" && item.detailURL != nil) else { return }
        let requestRevision = revision
        isLoading = true
        errorMessage = nil
        defer { if revision == requestRevision { isLoading = false } }
        do {
            let updated = try await load(item)
            try Task.checkCancellation()
            guard revision == requestRevision else { return }
            item = updated
        } catch {
            guard revision == requestRevision, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
