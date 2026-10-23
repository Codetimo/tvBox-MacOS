import SwiftUI
import AVKit
import AppKit
import Security

@main
struct TVBoxMacOSApp: App {
    @StateObject private var spiderService = SpiderService()
    var body: some Scene { Window("影视仓", id: "library") { ChannelBrowserView(spiderService: spiderService) } }
}

private enum TVSection: String, CaseIterable, Identifiable {
    case home, movies, live, favorites, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"
        case .movies: return "影视"
        case .live: return "直播"
        case .favorites: return "收藏"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .movies: return "film"
        case .live: return "dot.radiowaves.left.and.right"
        case .favorites: return "star.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ChannelBrowserView: View {
    @StateObject private var playback = PlaybackCoordinator()
    @ObservedObject var spiderService: SpiderService
    @ObservedObject private var panCookies = PanCookieStore.shared
    @State private var library = SourceLibrary()
    @State private var searchText = ""
    @State private var sourceURLText = ""
    @State private var selectedGroup = "全部"
    @State private var favoriteIDs: Set<String> = []
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var mediaResults: [TVMediaItem] = []
    @State private var selectedProvider = "全部"
    @State private var providerState = SearchProviderState()
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedSection: TVSection = .home
    @State private var selectedMovie: TVMediaItem?
    @StateObject private var playbackWindow = PlaybackWindowController()
    @StateObject private var searchHistory = SearchHistoryStore()
    @StateObject private var movieFavorites = MovieFavoritesStore()
    @AppStorage(PlaybackSettings.seekStepKey) private var playbackSeekStepSeconds = PlaybackSettings.defaultSeekStepSeconds
    @State private var store = SourceLibraryRepository()
    private var channels: [TVChannel] { deduplicatedChannels(library.sources.compactMap { $0.snapshot?.channels }.flatMap { $0 }) }
    private var groups: [String] { ["全部"] + Set(channels.map(\.group)).sorted() }
    private var filteredChannels: [TVChannel] { channels.filter { c in (selectedGroup == "全部" || c.group == selectedGroup) && (searchText.isEmpty || c.name.localizedCaseInsensitiveContains(searchText) || c.group.localizedCaseInsensitiveContains(searchText)) } }
    private var filteredMediaResults: [TVMediaItem] { selectedProvider == "全部" ? mediaResults : mediaResults.filter { providerState.providerID(for: $0) == selectedProvider } }

    var body: some View {
        NavigationSplitView {
            TVSidebar(selectedSection: $selectedSection, channelCount: channels.count, favoriteCount: favoriteIDs.count + movieFavorites.items.count, sourceCount: library.sources.count)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                TVTopBar(title: selectedSection.title, searchText: $searchText, suggestions: SearchSuggestionEngine.suggestions(query: searchText, history: searchHistory.entries, mediaNames: mediaResults.map(\.name) + movieFavorites.items.map(\.name), channelNames: channels.map(\.name), groupNames: groups.filter { $0 != "全部" }), isSearching: isSearching, clearSearchHistory: searchHistory.clear, selectSuggestion: selectSearchSuggestion, search: beginOrCancelSearch)
                    .zIndex(10)
                Divider()
                if let error = movieFavorites.errorMessage {
                    StatusBanner(message: error).padding(.horizontal, 28).padding(.top, 10)
                }
                contentView
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1100, minHeight: 700)
        // 站源中存在可搜索的 Spider 时后台预热，首搜直接复用启动任务。
        // 纯远程 API 配置不会触发 Android 运行时启动。
        .task {
            await loadLibrary(); loadFavorites()
            async let repair: Void = repairStoredLivePlaylists()
            await prewarmSpiderIfNeeded()
            await repair
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in playback.stop(); spiderService.stop() }
        .onDisappear { searchTask?.cancel(); playbackWindow.close(); playback.stop() }
        .onReceive(panCookies.$revision.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            Task { await synchronizePanCookies() }
        }
        .onChange(of: favoriteIDs) { _ in saveFavorites() }
        .sheet(item: $selectedMovie) { item in
            MovieDetailView(item: item, searchResults: mediaResults, favorites: movieFavorites, loadDetail: { summary in
                try await loadMovieDetail(summary)
            }, play: { detail, source in
                playMedia(item: detail, source: source)
            })
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedSection {
        case .home: homeView
        case .movies: moviesView
        case .live: liveView
        case .favorites: favoritesView
        case .settings: settingsView
        }
    }

    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("今天看点什么？").font(.system(size: 30, weight: .bold))
                        Text("搜索影片、打开直播，或从收藏继续观看").font(.title3).foregroundStyle(.white.opacity(0.78))
                        HStack(spacing: 10) {
                            Button { selectedSection = .movies } label: { Label("搜索影片", systemImage: "magnifyingglass") }.buttonStyle(.borderedProminent)
                            Button { selectedSection = .live } label: { Label("打开直播", systemImage: "play.tv") }.buttonStyle(.bordered)
                        }
                    }
                    Spacer()
                    Image(systemName: "play.tv.fill").font(.system(size: 86)).foregroundStyle(.white.opacity(0.9))
                }
                .padding(30)
                .background(LinearGradient(colors: [Color.indigo, Color.blue.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)

                HStack(spacing: 14) {
                    TVStatCard(title: "直播频道", value: "\(channels.count)", icon: "dot.radiowaves.left.and.right")
                    TVStatCard(title: "我的收藏", value: "\(favoriteIDs.count + movieFavorites.items.count)", icon: "star.fill")
                    TVStatCard(title: "已配置站源", value: "\(library.sources.count)", icon: "square.stack.3d.up.fill")
                }

                if !mediaResults.isEmpty {
                    SectionHeader(title: "最近搜索", actionTitle: "查看全部") { selectedSection = .movies }
                    movieGrid(items: Array(mediaResults.prefix(6)))
                } else {
                    SectionHeader(title: "直播频道", actionTitle: "查看全部") { selectedSection = .live }
                    if channels.isEmpty { EmptyState(title: "还没有站源", message: "进入设置导入 M3U 或 TVBox JSON 站源", icon: "tray") }
                    else { channelGrid(items: Array(channels.prefix(8))) }
                }
                if let statusMessage { StatusBanner(message: statusMessage) }
            }
            .padding(28)
        }
    }

    private var moviesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("影视").font(.title.bold()); Text(hasSearched ? "搜索结果会按站源合并展示" : "输入片名，搜索已配置的站源").foregroundStyle(.secondary) }
                    Spacer()
                    if hasSearched {
                        Picker("站源", selection: $selectedProvider) {
                            Text("全部站点").tag("全部")
                            ForEach(providerState.providers) { provider in
                                Text(providerState.label(for: provider)).tag(provider.id)
                            }
                        }.frame(width: 220)
                    }
                }
                if let provider = providerState.provider(id: selectedProvider) {
                    Text("\(providerState.label(for: provider))：\(provider.status)").font(.caption).foregroundStyle(.secondary)
                }
                if filteredMediaResults.isEmpty {
                    EmptyState(title: hasSearched ? "没有找到影片" : "开始搜索影片", message: hasSearched ? "换个关键词，或切换其他站源" : "在顶部搜索框输入片名并按回车", icon: "film")
                } else { movieGrid(items: filteredMediaResults) }
                if let statusMessage { StatusBanner(message: statusMessage) }
            }
            .padding(28)
        }
    }

    private var liveView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text("直播").font(.title.bold()); Text("按分组浏览频道，点击卡片即可播放").foregroundStyle(.secondary) }; Spacer(); Text("\(filteredChannels.count) 个频道").foregroundStyle(.secondary) }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(groups, id: \.self) { group in Button(group) { selectedGroup = group }.buttonStyle(.bordered).tint(selectedGroup == group ? .accentColor : .secondary) } } }
                if filteredChannels.isEmpty { EmptyState(title: channels.isEmpty ? "还没有直播源" : "没有匹配频道", message: channels.isEmpty ? "进入设置导入站源" : "尝试切换分组或搜索关键词", icon: "dot.radiowaves.left.and.right") }
                else { channelGrid(items: filteredChannels) }
                if let statusMessage { StatusBanner(message: statusMessage) }
            }
            .padding(28)
        }
    }

    private var favoritesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("收藏").font(.title.bold())
                Text("收藏的影片和频道会保存在本机").foregroundStyle(.secondary)
                let favorites = channels.filter { favoriteIDs.contains($0.id) }
                if movieFavorites.items.isEmpty && favorites.isEmpty {
                    EmptyState(title: "还没有收藏", message: "点击影片、播放窗口或直播频道上的收藏按钮", icon: "star")
                }
                if !movieFavorites.items.isEmpty {
                    Text("收藏影片").font(.headline)
                    movieGrid(items: movieFavorites.items)
                }
                if !favorites.isEmpty {
                    Text("收藏频道").font(.headline)
                    channelGrid(items: favorites)
                }
            }
            .padding(28)
        }
    }

    private var settingsView: some View {
        SettingsView(sourceURLText: $sourceURLText, playbackSeekStepSeconds: $playbackSeekStepSeconds, isLoading: isLoading, sources: library.sources, statusMessage: statusMessage, importRemote: { Task { await loadRemoteSource() } }, importLocal: importLocalFile, removeSource: removeSource, preparePanLogin: preparePanLogin)
            .padding(28)
    }

    @ViewBuilder private func movieGrid(items: [TVMediaItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 18)], spacing: 22) {
            ForEach(items) { item in MovieCard(item: item, isFavorite: movieFavorites.contains(item), isSavingFavorite: movieFavorites.isSaving, toggleFavorite: { movieFavorites.toggle(item) }, openDetail: { selectedMovie = item }, play: { source in playMediaFromCard(item: item, source: source) }) }
        }
    }

    @ViewBuilder private func channelGrid(items: [TVChannel]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 14)], spacing: 14) {
            ForEach(items) { channel in ChannelCard(channel: channel, isFavorite: favoriteIDs.contains(channel.id), play: { playChannel(channel) }, toggleFavorite: { toggleChannelFavorite(channel) }) }
        }
    }
    /// 频道卡片和失败重试共用入口，保留频道信息供播放窗口展示与收藏。
    @MainActor private func playChannel(_ channel: TVChannel) {
        playbackWindow.task?.cancel()
        playbackWindow.task = nil
        playbackWindow.movie = nil
        playbackWindow.source = nil
        playbackWindow.notice = nil
        playbackWindow.channel = channel
        playback.play(channel)
        presentPlaybackWindow(title: channel.name)
    }

    /// 所有直播收藏入口复用原有收藏标识，状态同步至主窗口与播放窗口。
    private func toggleChannelFavorite(_ channel: TVChannel) {
        if favoriteIDs.contains(channel.id) { favoriteIDs.remove(channel.id) }
        else { favoriteIDs.insert(channel.id) }
    }

    private func loadLibrary() async { do { library = try await store.load() } catch { statusMessage = error.localizedDescription } }
    private func loadFavorites() { favoriteIDs = Set(UserDefaults.standard.stringArray(forKey: "favoriteChannelIDs") ?? []) }
    /// 后台展开旧版本误保存的直播列表；源被删除或重新导入时丢弃旧修复结果。
    @MainActor private func repairStoredLivePlaylists() async {
        let loader = SourceLoader()
        for stored in library.sources {
            guard !Task.isCancelled else { return }
            guard let original = stored.snapshot,
                  let repaired = await loader.repairStoredLivePlaylists(in: original),
                  !Task.isCancelled,
                  library.sources.first(where: { $0.id == stored.id }) == stored else { continue }
            do {
                library = try await store.replace(snapshot: repaired, ifUnchanged: stored)
                let addedWarnings = repaired.warnings.filter { !original.warnings.contains($0) }
                statusMessage = addedWarnings.isEmpty ? "直播列表已更新，共 \(repaired.channels.count) 个频道。" : addedWarnings.joined(separator: "\n")
            } catch {
                statusMessage = "保存修复后的直播列表失败：\(error.localizedDescription)"
            }
        }
    }

    /// 后台读取站源目录并预热需要 Spider 的桥接服务，避免用户首次搜索时等待冷启动。
    @MainActor private func prewarmSpiderIfNeeded() async {
        let sources = library.sources.filter { $0.source.kind == .tvboxJSON }
        guard !sources.isEmpty else { return }
        let loader = SourceLoader()
        let needsSpider = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for stored in sources {
                group.addTask {
                    guard let catalog = try? await loader.loadCatalog(source: stored.source) else { return false }
                    return catalog.contains { $0.searchable && $0.usesSpider }
                }
            }
            for await found in group where found { group.cancelAll(); return true }
            return false
        }
        guard needsSpider, !spiderService.isReady else { return }
        await spiderService.start()
    }
    /// 优先使用站源的网盘配置入口；逐个包尝试，避免某个旧站源阻断扫码。
    @MainActor private func preparePanLogin() async throws -> [PanLoginConnection] {
        let loader = SourceLoader()
        var sites: [TVBoxSite] = []
        for stored in library.sources where stored.source.kind == .tvboxJSON {
            try Task.checkCancellation()
            if let catalog = try? await loader.loadCatalog(source: stored.source) {
                sites.append(contentsOf: catalog.filter { $0.usesSpider && $0.spiderURL != nil })
            }
        }
        sites.sort { ($0.adapter?.contains("PanConfig") == true ? 0 : 1) < ($1.adapter?.contains("PanConfig") == true ? 0 : 1) }
        var packages = Set<String>()
        sites = sites.filter { packages.insert($0.spiderURL!.absoluteString).inserted }
        guard !sites.isEmpty else { throw SourceParseError.invalidInput("请先添加支持网盘扫码登录的 TVBox 站源。") }
        await spiderService.start()
        guard await spiderService.waitUntilReady() else {
            throw SourceParseError.invalidInput("本地扫码服务尚未就绪，请稍后刷新二维码。")
        }
        return sites.map { PanLoginConnection(site: $0, baseURL: spiderService.baseURL, token: spiderService.token) }
    }

    /// 登录与退出后同步每个 Spider 包；后续播放请求也会重试，避免桥接重启丢失状态。
    @MainActor private func synchronizePanCookies() async {
        let loader = SourceLoader()
        var packages = Set<String>()
        var sites: [TVBoxSite] = []
        var failed = false
        for stored in library.sources where stored.source.kind == .tvboxJSON {
            do {
                for site in try await loader.loadCatalog(source: stored.source) where site.usesSpider {
                    if let url = site.spiderURL, packages.insert(url.absoluteString).inserted { sites.append(site) }
                }
            } catch { failed = true }
        }
        guard !sites.isEmpty else {
            if failed { statusMessage = "网盘凭据已在本机更新；站源加载失败，下次播放时重试同步。" }
            return
        }
        await spiderService.start()
        guard await spiderService.waitUntilReady() else {
            statusMessage = "网盘凭据已在本机更新；本地服务尚未就绪，下次播放时重试。"
            return
        }
        for site in sites {
            do { try await loader.synchronizePanCookies(site: site, baseURL: spiderService.baseURL, token: spiderService.token) }
            catch { failed = true }
        }
        statusMessage = failed ? "网盘凭据已在本机更新；部分站源同步失败，下次播放时重试。" : "网盘凭据已同步到本地播放服务。"
    }

    private func saveFavorites() { UserDefaults.standard.set(Array(favoriteIDs).sorted(), forKey: "favoriteChannelIDs") }
    /// 导入后的存储事务在后台串行执行，完成后才发布成功状态。
    @MainActor private func save(_ snapshot: SourceSnapshot) async {
        do {
            SourceLoader.invalidateCatalog(url: snapshot.source.location)
            library = try await store.upsert(snapshot: snapshot)
            statusMessage = "已导入 \(snapshot.channels.count) 个频道"
            selectedGroup = "全部"
        } catch { statusMessage = "保存源失败：\(error.localizedDescription)" }
    }

    /// 网络读取与本地导入共用解析、列表展开及保存流程。
    @MainActor private func loadRemoteSource() async {
        guard let url = URL(string: sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            statusMessage = "URL 格式不正确"; return
        }
        isLoading = true
        statusMessage = "正在导入源…"
        defer { isLoading = false }
        do { await save(try await SourceLoader().load(url: url)) }
        catch { statusMessage = error.localizedDescription }
    }

    /// 文件选择在主线程执行，文件读取和远程列表展开使用异步加载入口。
    @MainActor private func importLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .text, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do { await save(try await SourceLoader().load(fileURL: url)) }
            catch { statusMessage = error.localizedDescription }
        }
    }

    /// 删除也进入同一个存储 actor，避免与导入的读改写事务相互覆盖。
    @MainActor private func removeSource(_ source: StoredSource) {
        Task {
            do {
                SourceLoader.invalidateCatalog(url: source.source.location)
                library = try await store.remove(sourceID: source.id)
                statusMessage = "已删除源：\(source.source.name)"
            } catch { statusMessage = error.localizedDescription }
        }
    }

    /// 明确选择频道或分组建议时进入直播筛选，影片和历史建议保留站源搜索。
    @MainActor private func selectSearchSuggestion(_ suggestion: SearchSuggestion) {
        searchText = suggestion.text
        switch suggestion.source {
        case .channel:
            selectedGroup = "全部"
            selectedSection = .live
        case .group:
            selectedGroup = suggestion.text
            selectedSection = .live
        case .movie, .history:
            beginOrCancelSearch()
        }
    }

    /// 搜索按钮在查询期间提供取消入口，保留已经返回的结果。
    @MainActor private func beginOrCancelSearch() {
        if isSearching { searchTask?.cancel(); return }
        searchTask = Task { await searchMovies() }
    }

    @MainActor
    private func searchMovies() async {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSearching else { return }
        guard !keyword.isEmpty else { mediaResults = []; hasSearched = false; return }
        searchHistory.record(keyword)
        selectedSection = .movies
        hasSearched = true; mediaResults = []; providerState = SearchProviderState(); selectedProvider = "全部"
        isSearching = true; statusMessage = "正在搜索影片…"
        defer {
            isSearching = false
            searchTask = nil
        }
        let loader = SourceLoader()
        let service = spiderService
        var results: [TVMediaItem] = []
        func sortedUnique(_ values: [TVMediaItem]) -> [TVMediaItem] {
            var seen = Set<String>()
            return values.enumerated().sorted {
                let left = TVBoxSearchParser.searchRelevanceScore(name: $0.element.name, keyword: keyword)
                let right = TVBoxSearchParser.searchRelevanceScore(name: $1.element.name, keyword: keyword)
                return left == right ? $0.offset < $1.offset : left > right
            }.filter { seen.insert($0.element.id).inserted }.map(\.element)
        }
        await SearchPipeline.run(sources: library.sources.map(\.source).filter { $0.kind == .tvboxJSON },
            loadCatalog: { try await loader.loadCatalog(source: $0) },
            search: { site in
                try await MovieApplicationService(spider: service, loader: loader).search(site: site, keyword: keyword)
            }, receive: { event in
                guard !Task.isCancelled else { return }
                switch event {
                case .catalog(let source, let sites):
                    providerState.catalog(sites, source: source)
                case .catalogFailure(let source, _):
                    providerState.catalogFailed(source)
                case .result(let site, let result):
                    providerState.result(result, site: site)
                    switch result {
                    case .success(let found):
                        results.append(contentsOf: found)
                        mediaResults = sortedUnique(results)
                    case .failure: break
                    }
                    statusMessage = "已找到 \(mediaResults.count) 条结果，正在查询其他站点…"
                }
            })
        guard !Task.isCancelled else {
            statusMessage = "搜索已取消，保留 \(mediaResults.count) 条已返回结果。"
            return
        }
        do {
            if results.isEmpty { results = try await loader.searchFallback(keyword: keyword) }
            try Task.checkCancellation()
            mediaResults = sortedUnique(results)
            providerState.fallback(mediaResults)
            statusMessage = mediaResults.isEmpty ? "没有找到影片，可通过站源筛选查看各站状态。"
                : "找到 \(mediaResults.count) 条结果，来自 \(Set(mediaResults.compactMap { providerState.providerID(for: $0) }).count) 个站点"
        } catch {
            statusMessage = Task.isCancelled ? "搜索已取消。" : "公开目录检索失败，可通过站源筛选查看各站状态。"
        }
    }

    @MainActor
    private func loadMovieDetail(_ item: TVMediaItem) async throws -> TVMediaItem {
        let detail = try await MovieApplicationService(spider: spiderService).detail(for: item)
        try Task.checkCancellation()
        if let index = mediaResults.firstIndex(where: { $0.id == item.id }) { mediaResults[index] = detail }
        movieFavorites.refresh(detail)
        return detail
    }

    /// 所有播放入口共用同一窗口及播放器；关闭窗口会使尚未完成的解析失效。
    @MainActor private func presentPlaybackWindow(title: String) {
        playbackWindow.present(title: title, content: PlaybackWindowView(playback: playback, presentation: playbackWindow, favorites: movieFavorites, favoriteChannelIDs: $favoriteIDs, playChannel: playChannel, toggleChannelFavorite: toggleChannelFavorite) { item, source in
            playMedia(item: item, source: source)
        }) {
            playback.stop()
        }
    }

    /// 卡片可绕过详情页直接选集，因此播放前刷新收藏快照并按线路与剧集对应新地址。
    @MainActor private func playMediaFromCard(item: TVMediaItem, source: TVPlaySource) {
        guard movieFavorites.contains(item), item.spiderSite != nil || item.detailURL != nil && item.siteKey != "public" else {
            playMedia(item: item, source: source)
            return
        }
        playbackWindow.task?.cancel()
        playbackWindow.channel = nil
        playbackWindow.movie = item
        playbackWindow.source = source
        playbackWindow.notice = "正在刷新收藏详情…"
        playback.stop()
        playback.clearError()
        presentPlaybackWindow(title: item.name)
        playbackWindow.task = Task {
            do {
                let refreshed = try await loadMovieDetail(item)
                try Task.checkCancellation()
                guard let selected = MovieApplicationService.refreshedSource(source, in: refreshed) else {
                    playbackWindow.movie = refreshed
                    playbackWindow.source = nil
                    playbackWindow.notice = "原剧集已变更，请重新选择线路或剧集。"
                    return
                }
                playMedia(item: refreshed, source: selected)
            } catch {
                guard !Task.isCancelled else { return }
                playMedia(item: item, source: source, recoveryNotice: "详情刷新失败，正在尝试上次保存的线路。")
            }
        }
    }

    @MainActor
    private func playMedia(item: TVMediaItem, source: TVPlaySource, failedSources: Set<TVPlaySource> = [], recoveryNotice: String? = nil) {
        playbackWindow.task?.cancel()
        playbackWindow.channel = nil
        playbackWindow.movie = item
        playbackWindow.source = source
        playbackWindow.notice = "正在解析：\(source.flag ?? source.name)"
        statusMessage = "正在解析《\(item.name)》· \(source.name)…"
        // 解析前打开唯一播放窗口，进度、失败原因和重试入口始终可见。
        selectedMovie = nil
        presentPlaybackWindow(title: item.name)
        playback.stop()
        playback.clearError()
        playbackWindow.task = Task {
            do {
                let selection = try await PlaybackRouteResolver.resolve(source: source, sources: item.playSources.filter { !failedSources.contains($0) }) { candidate in
                    try Task.checkCancellation()
                    playbackWindow.notice = "正在解析：\(candidate.flag ?? candidate.name)"
                    return try await MovieApplicationService(spider: spiderService).resolve(item: item, source: candidate)
                }
                try Task.checkCancellation()
                playbackWindow.source = selection.source
                let resolved = selection.playback
                let playbackURL = resolved.url
                playbackWindow.notice = selection.notice ?? recoveryNotice ?? "\(item.name) · \(selection.source.flag ?? selection.source.name)"
                if resolved.isDirect {
                    playback.play(TVChannel(id: item.id + resolved.url.absoluteString, name: item.name, group: "\(item.sourceName) · \(selection.source.name)", logoURL: item.posterURL, streamURL: playbackURL, headers: resolved.headers)) {
                        // 仅启动失败时换源，最多切换两次；用户手动选集会开始新一轮。
                        guard playbackWindow.movie?.id == item.id, playbackWindow.source == selection.source, failedSources.count < 2 else { return }
                        let failed = failedSources.union([source, selection.source])
                        let alternatives = PlaybackRouteResolver.alternatives(for: selection.source, in: item.playSources)
                        guard let next = alternatives.first(where: { !failed.contains($0) }) else { return }
                        playMedia(item: item, source: next, failedSources: failed,
                                  recoveryNotice: "\(selection.source.routeName)无法打开，已切换到\(next.routeName) · \(next.episodeName)")
                    }
                    statusMessage = "正在播放《\(item.name)》· \(item.sourceName) · \(selection.source.name)"
                } else {
                    playback.openWeb(playbackURL)
                    statusMessage = "正在打开《\(item.name)》的播放页"
                }
            } catch {
                guard !Task.isCancelled else { return }
                playbackWindow.notice = "\(item.name) · \(source.flag ?? source.name)"
                let message = "播放解析失败：\(error.localizedDescription)"
                statusMessage = message
                // Spider 的授权、解析器等错误发生在 AVPlayer 创建前，不能依赖
                // PlaybackCoordinator.play(_:) 的 KVO 错误回调来展示。
                playback.showError(message)
            }
        }
    }

}

/// 独立播放窗口观察同一会话，解析状态和选集变化无需重建播放器。
private struct PlaybackWindowView: View {
    @ObservedObject var playback: PlaybackCoordinator
    @ObservedObject var presentation: PlaybackWindowController
    @ObservedObject var favorites: MovieFavoritesStore
    @Binding var favoriteChannelIDs: Set<String>
    let playChannel: (TVChannel) -> Void
    let toggleChannelFavorite: (TVChannel) -> Void
    let play: (TVMediaItem, TVPlaySource) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let item = presentation.movie {
                        HStack {
                            Text(item.name).font(.title2.bold())
                            Spacer()
                            MovieFavoriteButton(item: item, favorites: favorites)
                        }
                        if let error = favorites.errorMessage { StatusBanner(message: error) }
                        Text(presentation.notice ?? presentation.source?.name ?? "选择剧集")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let channel = presentation.channel {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channel.name).font(.title2.bold())
                                Text(channel.group).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { toggleChannelFavorite(channel) } label: {
                                Label(favoriteChannelIDs.contains(channel.id) ? "取消收藏" : "收藏",
                                      systemImage: favoriteChannelIDs.contains(channel.id) ? "star.fill" : "star")
                            }.buttonStyle(.bordered)
                        }
                    }
                    ZStack {
                        Color.black
                        if let player = playback.player {
                            NativePlayerView(player: player, usesCompatibilityControls: playback.compatibilityNotice != nil, sourceDuration: playback.sourceDuration, timelineOffset: playback.timelineOffset, preparationMessage: playback.preparationMessage) { command in
                                switch command {
                                case .seek(let seconds): playback.seek(by: seconds)
                                case .seekTo(let seconds): playback.seek(to: seconds)
                                case .adjustVolume(let amount): playback.adjustVolume(by: amount)
                                }
                            }
                        } else if let webURL = playback.webURL {
                            NativeWebView(url: webURL)
                        } else {
                            Text(playback.preparationMessage ?? (presentation.movie == nil && presentation.channel == nil ? "选择影片或频道开始播放" : "正在准备播放…"))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        if let error = playback.errorMessage {
                            VStack(spacing: 12) {
                                Label("播放未能开始", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(maxHeight: 120)
                                HStack {
                                    if let item = presentation.movie, let source = presentation.source {
                                        Button("重新解析播放") { play(item, source) }
                                    }
                                    if let channel = presentation.channel {
                                        Button("重试直播") { playChannel(channel) }
                                    }
                                    Button("关闭提示") { playback.clearError() }
                                }
                            }
                            .padding(20).frame(maxWidth: 440)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(width: max(0, geometry.size.width - 48), height: max(240, min((geometry.size.width - 48) * 9 / 16, presentation.movie == nil ? max(240, geometry.size.height - 140) : geometry.size.height * 0.52)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    if let notice = playback.compatibilityNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if let item = presentation.movie {
                        PlaybackSourcePicker(sources: item.playSources, selected: presentation.source) { source in
                            play(item, source)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

}

/// 分开展示线路与剧集；换线路先浏览剧集，避免误播同名序号不一致的内容。
private struct PlaybackSourcePicker: View {
    let sources: [TVPlaySource]
    let selected: TVPlaySource?
    let play: (TVPlaySource) -> Void
    @State private var browsingRoute: String?

    private var routes: [String] {
        var seen = Set<String>()
        return sources.map(\.routeName).filter { seen.insert($0).inserted }
    }
    private var activeRoute: String { browsingRoute ?? selected?.routeName ?? routes.first ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("切换线路").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(routes, id: \.self) { route in
                    Button { browsingRoute = route } label: {
                        Text(route)
                            .font(.callout)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .buttonStyle(PlaybackSourceButtonStyle(isSelected: activeRoute == route))
                    .help(route)
                }
            }
            HStack {
                Text("选集 · \(activeRoute)").font(.headline)
                Spacer()
                Text("点击剧集播放").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(Array(sources.filter { $0.routeName == activeRoute }.enumerated()), id: \.offset) { _, source in
                    Button { play(source) } label: {
                        HStack(spacing: 8) {
                            if source == selected {
                                Image(systemName: "play.fill").font(.caption)
                            }
                            Text(source.episodeName)
                                .font(.callout)
                                .lineLimit(2, reservesSpace: true)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    }
                    .buttonStyle(PlaybackSourceButtonStyle(isSelected: source == selected))
                    .help(source.episodeName)
                    .accessibilityLabel(source.episodeName)
                    .accessibilityValue(source == selected ? "当前播放" : "")
                }
            }
        }
        .onChange(of: selected) { source in browsingRoute = source?.routeName }
    }
}

/// 自绘选集边框，让按钮高度跟随多行文字，避免 macOS 原生按钮边框压缩内容。
private struct PlaybackSourceButtonStyle: ButtonStyle {
    let isSelected: Bool

    /// 将完整标签纳入点击区域，并通过边框与底色标出当前线路或剧集。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct TVSidebar: View {
    @Binding var selectedSection: TVSection
    let channelCount: Int
    let favoriteCount: Int
    let sourceCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.tv.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) { Text("影视仓").font(.headline); Text("TVBox for Mac").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 26)
            VStack(spacing: 4) {
                sidebarButton(.home); sidebarButton(.movies); sidebarButton(.live, badge: channelCount); sidebarButton(.favorites, badge: favoriteCount)
            }.padding(.horizontal, 10)
            Spacer()
            HStack(spacing: 8) { Image(systemName: "square.stack.3d.up"); Text("已配置 \(sourceCount) 个站源") }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 12)
            sidebarButton(.settings).padding(.horizontal, 10).padding(.bottom, 14)
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private func sidebarButton(_ section: TVSection, badge: Int? = nil) -> some View {
        Button { selectedSection = section } label: {
            HStack(spacing: 12) { Image(systemName: section.icon).frame(width: 18); Text(section.title); Spacer(); if let badge, badge > 0 { Text("\(badge)").font(.caption2).foregroundStyle(.secondary) } }
                .font(.body.weight(selectedSection == section ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                .background(selectedSection == section ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(selectedSection == section ? Color.accentColor : .primary)
        }.buttonStyle(.plain)
    }
}

private struct TVTopBar: View {
    let title: String
    @Binding var searchText: String
    let suggestions: [SearchSuggestion]
    let isSearching: Bool
    let clearSearchHistory: () -> Void
    let selectSuggestion: (SearchSuggestion) -> Void
    let search: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.title2.bold()); Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SearchSuggestionField(text: $searchText, suggestions: suggestions, onSubmit: search, onClearHistory: clearSearchHistory, onSelect: selectSuggestion).frame(width: 250)
                if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Button(isSearching ? "取消搜索" : "搜索", action: search).buttonStyle(.borderedProminent).controlSize(.small).disabled(!isSearching && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 10).padding(.vertical, 6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }.padding(.horizontal, 28).padding(.vertical, 14)
    }
}

private struct TVStatCard: View {
    let title: String; let value: String; let icon: String
    var body: some View { HStack(spacing: 12) { Image(systemName: icon).font(.title3).foregroundStyle(.blue).frame(width: 30, height: 30).background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)); VStack(alignment: .leading, spacing: 2) { Text(value).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(14).frame(maxWidth: .infinity).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) }
}

private struct SectionHeader: View {
    let title: String; let actionTitle: String; let action: () -> Void
    var body: some View { HStack { Text(title).font(.title3.bold()); Spacer(); Button(actionTitle, action: action).buttonStyle(.link) } }
}

private struct StatusBanner: View {
    let message: String
    var body: some View { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)) }
}

private struct EmptyState: View {
    let title: String; let message: String; let icon: String
    var body: some View { VStack(spacing: 10) { Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.secondary); Text(title).font(.headline); Text(message).font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 180).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)) }
}

private struct ChannelCard: View {
    let channel: TVChannel; let isFavorite: Bool; let play: () -> Void; let toggleFavorite: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if let logoURL = channel.logoURL { AsyncImage(url: logoURL) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }.frame(width: 52, height: 52).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8)) }
            else { Image(systemName: "tv").font(.title2).foregroundStyle(.blue).frame(width: 52, height: 52).background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8)) }
            VStack(alignment: .leading, spacing: 4) { Text(channel.name).font(.body.weight(.medium)).lineLimit(2); Text(channel.group).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(); VStack(spacing: 8) { Button(action: play) { Image(systemName: "play.fill") }.buttonStyle(.borderedProminent).controlSize(.small); Button(action: toggleFavorite) { Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star") }.buttonStyle(.bordered).controlSize(.small).foregroundStyle(isFavorite ? .orange : .secondary) }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MovieCard: View {
    let item: TVMediaItem; let isFavorite: Bool; let isSavingFavorite: Bool; let toggleFavorite: () -> Void
    let openDetail: () -> Void; let play: (TVPlaySource) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: item.posterURL) { phase in
                    switch phase { case .success(let image): image.resizable().scaledToFill(); default: ZStack { Color.secondary.opacity(0.14); Image(systemName: "film").font(.title).foregroundStyle(.secondary) } }
                }.frame(maxWidth: .infinity).aspectRatio(0.68, contentMode: .fit).clipped().background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                if let remark = item.remark, !remark.isEmpty { Text(remark).font(.caption2).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white).padding(7) }
            }
            Text(item.name).font(.body.weight(.semibold)).lineLimit(2); Text(item.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Button(action: toggleFavorite) { Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star") }.disabled(isSavingFavorite)
                Button("详情", action: openDetail)
            }.buttonStyle(.bordered).controlSize(.small)
            if item.playSources.isEmpty { Button("查看详情", action: openDetail).buttonStyle(.bordered).controlSize(.small) }
            else { Menu { ForEach(Array(item.playSources.enumerated()), id: \.offset) { _, source in Button(source.name) { play(source) } } } label: { Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.small) }
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            // 详情页统一承载摘要加载和已有线路展示，点击卡片任意区域均可进入。
            openDetail()
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 详情与播放窗口共用明确文案的收藏入口，状态由实际持久化结果驱动。
private struct MovieFavoriteButton: View {
    let item: TVMediaItem
    @ObservedObject var favorites: MovieFavoritesStore

    var body: some View {
        Button { favorites.toggle(item) } label: {
            Label(favorites.contains(item) ? "取消收藏" : "收藏",
                  systemImage: favorites.contains(item) ? "star.fill" : "star")
        }.buttonStyle(.bordered).disabled(favorites.isSaving)
    }
}

private struct MovieDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MovieDetailModel
    @State private var refreshGeneration = UUID()
    private var detail: TVMediaItem { model.item }
    let searchResults: [TVMediaItem]
    @ObservedObject var favorites: MovieFavoritesStore
    let loadDetail: (TVMediaItem) async throws -> TVMediaItem
    let play: (TVMediaItem, TVPlaySource) -> Void

    init(item: TVMediaItem, searchResults: [TVMediaItem], favorites: MovieFavoritesStore, loadDetail: @escaping (TVMediaItem) async throws -> TVMediaItem,
         play: @escaping (TVMediaItem, TVPlaySource) -> Void) {
        _model = StateObject(wrappedValue: MovieDetailModel(item: item))
        self.searchResults = searchResults
        self.favorites = favorites
        self.loadDetail = loadDetail
        self.play = play
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                poster
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.name).font(.title2.bold())
                    Text(detail.sourceName).font(.callout).foregroundStyle(.secondary)
                    MovieFavoriteButton(item: detail, favorites: favorites)
                    if let error = favorites.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                    if let remark = detail.remark, !remark.isEmpty { Text(remark).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            Divider()
            if model.isLoading {
                ProgressView("正在刷新详情…").frame(maxWidth: .infinity)
            }
            if let errorMessage = model.errorMessage {
                VStack(spacing: 10) {
                    Label("详情刷新失败：\(errorMessage)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { refreshGeneration = UUID() }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, minHeight: 100)
                if !alternativeResults.isEmpty {
                    Text("本次搜索的其他站点").font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(alternativeResults) { candidate in
                                Button {
                                    model.select(candidate)
                                } label: {
                                    Text("\(candidate.siteName) · \(candidate.name)")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            if detail.playSources.isEmpty && !model.isLoading && model.errorMessage == nil {
                Text("站点未返回可播放线路").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            } else if !detail.playSources.isEmpty {
                if model.errorMessage != nil { Text("当前显示上次保存的线路，可尝试播放或重试刷新。").font(.caption).foregroundStyle(.secondary) }
                Text("播放线路").font(.headline)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(detail.playSources.enumerated()), id: \.offset) { _, source in
                            Button { play(detail, source) } label: {
                                HStack { Text(source.name); Spacer(); Image(systemName: "play.fill") }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.bordered).disabled(model.isLoading)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        // 重试和切换站点共用随 sheet 生命周期取消的任务，迟到响应不得写回收藏。
        .task(id: detail.id + refreshGeneration.uuidString) { await model.refresh(using: loadDetail) }
    }

    /// 只展示当前搜索中其他站点的真实结果，由用户核对片名后选择，避免自动误播同名影片。
    private var alternativeResults: [TVMediaItem] {
        searchResults.filter {
            $0.id != detail.id && $0.siteKey != "public"
                && ($0.siteKey != detail.siteKey || $0.sourceName != detail.sourceName || $0.spiderSite != detail.spiderSite)
        }
    }

    @ViewBuilder
    private var poster: some View {
        AsyncImage(url: detail.posterURL) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: ZStack { Color.secondary.opacity(0.14); Image(systemName: "film").font(.title).foregroundStyle(.secondary) }
            }
        }
        .frame(width: 110, height: 155)
        .clipped()
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

}

private struct SettingsView: View {
    @Binding var sourceURLText: String
    @Binding var playbackSeekStepSeconds: Double
    let isLoading: Bool; let sources: [StoredSource]; let statusMessage: String?
    let importRemote: () -> Void; let importLocal: () -> Void; let removeSource: (StoredSource) -> Void
    let preparePanLogin: () async throws -> [PanLoginConnection]
    @ObservedObject private var cookieStore = PanCookieStore.shared
    @State private var loginProvider: PanCookieStore.Provider?
    @State private var cookieErrorMessage: String?
    var body: some View {
        Form {
            Section("播放器") {
                Stepper(value: $playbackSeekStepSeconds, in: 1...300, step: 1) {
                    Text("左右方向键步长：\(Int(playbackSeekStepSeconds)) 秒")
                }
                Text("播放时按 Enter 进入或退出全屏；左右方向键调整进度，上下方向键以 5% 步长调整音量，Esc 退出全屏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("网盘登录") {
                Text("使用网盘 App 扫描二维码登录，凭据保存在本机钥匙串，用于播放解析。")
                    .font(.callout).foregroundStyle(.secondary)
                panLoginRow(.quark)
                panLoginRow(.baidu)
                if let cookieErrorMessage { Text(cookieErrorMessage).font(.caption).foregroundStyle(.red) }
            }
            Section("站源管理") {
                Text("导入远程 M3U / TVBox JSON，或选择本地文件。导入后会保存到本机。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("站源 URL", text: $sourceURLText).textFieldStyle(.roundedBorder)
                    Button(isLoading ? "导入中…" : "导入", action: importRemote)
                        .disabled(isLoading || sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("打开本地文件…", action: importLocal).disabled(isLoading)
                if let statusMessage { Text(statusMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Section("已保存站源") {
                if sources.isEmpty { Text("暂无站源").foregroundStyle(.secondary) }
                else {
                    ForEach(sources) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.source.name)
                                Text(item.source.location.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("删除", role: .destructive) { removeSource(item) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $loginProvider) { provider in
            PanLoginView(provider: provider, prepare: preparePanLogin)
        }
    }

    @ViewBuilder
    private func panLoginRow(_ provider: PanCookieStore.Provider) -> some View {
        let credentialStatus = cookieStore.credentialStatus(for: provider)
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.title)
                Text(credentialStatus == errSecSuccess ? "凭据已保存，可用性以播放结果为准" :
                     credentialStatus == errSecItemNotFound ? "未保存登录凭据" : "登录信息暂不可读，可重新扫码登录")
                    .font(.caption).foregroundStyle(credentialStatus == errSecSuccess ? Color.green : Color.secondary)
            }
            Spacer()
            Button("扫码登录") { loginProvider = provider }.buttonStyle(.borderedProminent)
            if credentialStatus != errSecItemNotFound {
                Button("清除登录信息") {
                    do { try cookieStore.remove(provider: provider); cookieErrorMessage = nil }
                    catch { cookieErrorMessage = error.localizedDescription }
                }.buttonStyle(.bordered)
            }
        }
    }
}
