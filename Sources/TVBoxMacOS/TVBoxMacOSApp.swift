import SwiftUI
import AVKit
import AppKit
import Security

@main
struct TVBoxMacOSApp: App { var body: some Scene { WindowGroup { ChannelBrowserView() } } }

private enum TVSection: String, CaseIterable, Identifiable {
    case home, movies, live, favorites, player, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"
        case .movies: return "影视"
        case .live: return "直播"
        case .favorites: return "收藏"
        case .player: return "正在播放"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .movies: return "film"
        case .live: return "dot.radiowaves.left.and.right"
        case .favorites: return "star.fill"
        case .player: return "play.rectangle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ChannelBrowserView: View {
    @StateObject private var playback = PlaybackCoordinator()
    @StateObject private var spiderService = SpiderService()
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
    @State private var providerStatuses: [String: String] = [:]
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var selectedSection: TVSection = .home
    @State private var selectedMovie: TVMediaItem?
    @State private var playbackMovie: TVMediaItem?
    @State private var playbackSource: TVPlaySource?
    @State private var playbackNotice: String?
    @State private var playbackTask: Task<Void, Never>?
    @AppStorage(PlaybackSettings.seekStepKey) private var playbackSeekStepSeconds = PlaybackSettings.defaultSeekStepSeconds
    private let store = SourceStore()
    private var channels: [TVChannel] { deduplicatedChannels(library.sources.compactMap { $0.snapshot?.channels }.flatMap { $0 }) }
    private var groups: [String] { ["全部"] + Set(channels.map(\.group)).sorted() }
    private var filteredChannels: [TVChannel] { channels.filter { c in (selectedGroup == "全部" || c.group == selectedGroup) && (searchText.isEmpty || c.name.localizedCaseInsensitiveContains(searchText) || c.group.localizedCaseInsensitiveContains(searchText)) } }
    private var mediaProviders: [String] { ["全部"] + Set(mediaResults.map(\.sourceName) + Array(providerStatuses.keys)).sorted() }
    private var filteredMediaResults: [TVMediaItem] { selectedProvider == "全部" ? mediaResults : mediaResults.filter { $0.sourceName == selectedProvider } }

    var body: some View {
        NavigationSplitView {
            TVSidebar(selectedSection: $selectedSection, channelCount: channels.count, favoriteCount: favoriteIDs.count, sourceCount: library.sources.count)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                TVTopBar(title: selectedSection.title, searchText: $searchText, isSearching: isSearching, search: { Task { await searchMovies() } })
                Divider()
                contentView
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1100, minHeight: 700)
        // 站源中存在可快速搜索的 Spider 时后台预热，首搜直接复用启动任务。
        // 纯远程 API 配置不会触发 Android 运行时启动。
        .task {
            loadLibrary(); loadFavorites()
            await prewarmSpiderIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in playback.stop(); spiderService.stop() }
        .onReceive(panCookies.$revision.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            Task { await synchronizePanCookies() }
        }
        .onChange(of: favoriteIDs) { _ in saveFavorites() }
        .sheet(item: $selectedMovie) { item in
            MovieDetailView(item: item, loadDetail: { summary in
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
        case .player: playerView
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
                    TVStatCard(title: "收藏频道", value: "\(favoriteIDs.count)", icon: "star.fill")
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
                    if hasSearched { Picker("站源", selection: $selectedProvider) { ForEach(mediaProviders, id: \.self) { Text($0 == "全部" ? "全部站点" : $0).tag($0) } }.frame(width: 180) }
                }
                if let state = selectedProvider == "全部" ? nil : providerStatuses[selectedProvider] { Text("\(selectedProvider)：\(state)").font(.caption).foregroundStyle(.secondary) }
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
                Text("常用频道会保存在本机").foregroundStyle(.secondary)
                let favorites = channels.filter { favoriteIDs.contains($0.id) }
                if favorites.isEmpty { EmptyState(title: "还没有收藏", message: "在直播频道卡片上点击星标即可收藏", icon: "star") }
                else { channelGrid(items: favorites) }
            }
            .padding(28)
        }
    }

    private var settingsView: some View {
        SettingsView(sourceURLText: $sourceURLText, playbackSeekStepSeconds: $playbackSeekStepSeconds, isLoading: isLoading, sources: library.sources, statusMessage: statusMessage, importRemote: { Task { await loadRemoteSource() } }, importLocal: importLocalFile, removeSource: removeSource, preparePanLogin: preparePanLogin)
            .padding(28)
    }

    private var playerView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let item = playbackMovie {
                        Text(item.name).font(.title2.bold())
                        Text(playbackNotice ?? playbackSource?.name ?? "选择剧集")
                            .font(.callout).foregroundStyle(.secondary)
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
                            Text(playback.preparationMessage ?? (playbackMovie == nil ? "选择影片或频道开始播放" : "正在准备播放…"))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        if let error = playback.errorMessage {
                            VStack(spacing: 12) {
                                Label("播放未能开始", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(maxHeight: 120)
                                HStack {
                                    if let item = playbackMovie, let source = playbackSource {
                                        Button("重新解析播放") { playMedia(item: item, source: source) }
                                    }
                                    Button("关闭提示") { playback.clearError() }
                                }
                            }
                            .padding(20).frame(maxWidth: 440)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(width: max(0, geometry.size.width - 48), height: max(240, min((geometry.size.width - 48) * 9 / 16, geometry.size.height * 0.52)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    if let notice = playback.compatibilityNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if let item = playbackMovie {
                        PlaybackSourcePicker(sources: item.playSources, selected: playbackSource) { source in
                            playMedia(item: item, source: source)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder private func movieGrid(items: [TVMediaItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 18)], spacing: 22) {
            ForEach(items) { item in MovieCard(item: item, openDetail: { selectedMovie = item }, play: { source in playMedia(item: item, source: source) }) }
        }
    }

    @ViewBuilder private func channelGrid(items: [TVChannel]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 14)], spacing: 14) {
            ForEach(items) { channel in ChannelCard(channel: channel, isFavorite: favoriteIDs.contains(channel.id), play: { playbackTask?.cancel(); playbackMovie = nil; playbackSource = nil; playbackNotice = nil; playback.play(channel); selectedSection = .player }, toggleFavorite: { if favoriteIDs.contains(channel.id) { favoriteIDs.remove(channel.id) } else { favoriteIDs.insert(channel.id) } }) }
        }
    }
    private func loadLibrary() { do { library = try store.load() } catch { statusMessage = error.localizedDescription } }
    private func loadFavorites() { favoriteIDs = Set(UserDefaults.standard.stringArray(forKey: "favoriteChannelIDs") ?? []) }
    /// 后台读取站源目录并预热需要 Spider 的桥接服务，避免用户首次搜索时等待冷启动。
    @MainActor private func prewarmSpiderIfNeeded() async {
        let sources = library.sources.filter { $0.source.kind == .tvboxJSON }
        guard !sources.isEmpty else { return }
        let loader = SourceLoader()
        let needsSpider = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for stored in sources {
                group.addTask {
                    guard let catalog = try? await loader.loadCatalog(url: stored.source.location) else { return false }
                    return catalog.contains { $0.searchable && $0.usesSpider && $0.quickSearch }
                }
            }
            for await found in group where found { return true }
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
            if let catalog = try? await loader.loadCatalog(url: stored.source.location) {
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
                for site in try await loader.loadCatalog(url: stored.source.location) where site.usesSpider {
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
    @MainActor private func save(_ snapshot: SourceSnapshot) { do { SourceLoader.invalidateCatalog(url: snapshot.source.location); library = try store.upsert(snapshot: snapshot); statusMessage = "已导入 \(snapshot.channels.count) 个频道"; selectedGroup = "全部" } catch { statusMessage = "保存源失败：\(error.localizedDescription)" } }
    @MainActor private func loadRemoteSource() async { guard let url = URL(string: sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else { statusMessage = "URL 格式不正确"; return }; isLoading = true; statusMessage = "正在导入源…"; defer { isLoading = false }; do { save(try await SourceLoader().load(url: url)) } catch { statusMessage = error.localizedDescription } }
    private func importLocalFile() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .text, .plainText]; panel.allowsMultipleSelection = false; guard panel.runModal() == .OK, let url = panel.url else { return }; do { save(try SourceLoader().load(fileURL: url)) } catch { statusMessage = error.localizedDescription } }
    private func removeSource(_ source: StoredSource) { do { SourceLoader.invalidateCatalog(url: source.source.location); library = try store.remove(sourceID: source.id); statusMessage = "已删除源：\(source.source.name)" } catch { statusMessage = error.localizedDescription } }

    @MainActor
    private func searchMovies() async {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSearching else { return }
        guard !keyword.isEmpty else { mediaResults = []; hasSearched = false; return }
        hasSearched = true; mediaResults = []; providerStatuses = [:]; selectedProvider = "全部"
        isSearching = true; statusMessage = "正在搜索影片…"; defer { isSearching = false }
        // 远程 API 站点不依赖本地 Spider；只有目录中存在可快速搜索的 csp_*
        // 站点时才启动 Android 桥接服务，避免每次普通搜索都等待运行时准备。
        var spiderReady = spiderService.isReady
        // ready 状态由 SpiderService 的后台监视任务维护；这里直接复用，
        // 不要在每次搜索开始时再做一次串行健康检查。
        do {
            var results: [TVMediaItem] = []
            func sortedUnique(_ values: [TVMediaItem]) -> [TVMediaItem] {
                var seen = Set<String>()
                // 站点返回顺序是不确定的，按相关性排序，避免后返回的低匹配结果挤到前面。
                return values.enumerated().sorted {
                        let leftScore = TVBoxSearchParser.searchRelevanceScore(name: $0.element.name, keyword: keyword)
                        let rightScore = TVBoxSearchParser.searchRelevanceScore(name: $1.element.name, keyword: keyword)
                        if leftScore != rightScore { return leftScore > rightScore }
                        if $0.offset != $1.offset { return $0.offset < $1.offset }
                        return $0.element.id < $1.element.id
                    }
                    .filter { seen.insert($0.element.id).inserted }
                    .map(\.element)
            }
            let loader = SourceLoader()
            // 多个 TVBox 源的目录互不依赖，并发读取目录，避免逐个等待网络超时。
            let catalogs = await withTaskGroup(of: (String, Result<[TVBoxSite], Error>).self,
                                               returning: [String: Result<[TVBoxSite], Error>].self) { group in
                for item in library.sources where item.source.kind == .tvboxJSON {
                    group.addTask {
                        do { return (item.source.location.absoluteString, .success(try await loader.loadCatalog(url: item.source.location))) }
                        catch { return (item.source.location.absoluteString, .failure(error)) }
                    }
                }
                var loaded: [String: Result<[TVBoxSite], Error>] = [:]
                for await entry in group { loaded[entry.0] = entry.1 }
                return loaded
            }
            for item in library.sources where item.source.kind == .tvboxJSON {
                do {
                    guard let catalogResult = catalogs[item.source.location.absoluteString] else { continue }
                    let catalog = try catalogResult.get()
                    let requiresSpider = catalog.contains { $0.searchable && $0.usesSpider && $0.quickSearch }
                    if requiresSpider && !spiderReady {
                        statusMessage = "正在准备本地 Spider 服务…"
                        await spiderService.start()
                        spiderReady = await spiderService.waitUntilReady()
                        if !spiderReady {
                            statusMessage = "本地 Spider 服务未就绪：\(spiderService.state.message)"
                        } else {
                            statusMessage = "正在搜索影片…"
                        }
                    }
                    for site in catalog {
                        providerStatuses[site.name] = !site.searchable ? "站点已关闭搜索" : (site.usesSpider ? (!site.quickSearch ? "普通 Spider，未参与快速搜索" : (spiderReady ? "Spider 搜索中…" : "本地 Spider：\(spiderService.state.message)")) : (site.api == nil ? "暂不支持此脚本站点" : "搜索中…"))
                    }
                    let sites = catalog.filter { $0.searchable && ($0.api != nil || spiderReady && $0.usesSpider && $0.quickSearch) }
                    // 分批查询，限制同时请求的站点数量；每个站点保留独立状态。
                    for start in stride(from: 0, to: sites.count, by: 8) {
                        let batch = Array(sites[start..<min(start + 8, sites.count)])
                        let batchSpiderReady = batch.contains(where: \.usesSpider)
                            ? await spiderService.waitUntilReady(timeout: 30) : false
                        await withTaskGroup(of: (String, [TVMediaItem], String?).self) { group in
                            for site in batch {
                                group.addTask {
                                    do {
                                        return (site.name, try await loader.search(site: site, keyword: keyword, spiderBaseURL: batchSpiderReady ? spiderService.baseURL : nil, spiderToken: batchSpiderReady ? spiderService.token : nil), nil)
                                    }
                                    catch { return (site.name, [], error.localizedDescription) }
                                }
                            }
                            for await (name, found, error) in group {
                                results.append(contentsOf: found)
                                providerStatuses[name] = error.map { "查询失败：\($0)" } ?? (found.isEmpty ? "无匹配影片" : "\(found.count) 条结果")
                                // 站点按批次返回时立即刷新，慢站点不会阻塞已经找到的影片。
                                mediaResults = sortedUnique(results)
                                if !mediaResults.isEmpty {
                                    statusMessage = "已找到 \(mediaResults.count) 条结果，正在查询其他站点…"
                                }
                            }
                        }
                    }
                } catch { providerStatuses[item.source.name] = "配置读取失败：\(error.localizedDescription)" }
            }
            if results.isEmpty { results = try await SourceLoader().searchFallback(keyword: keyword) }
            mediaResults = sortedUnique(results)
            if mediaResults.contains(where: { $0.siteKey == "public" }) {
                providerStatuses["公开检索"] = "\(mediaResults.count) 条结果（第三方目录）"
            }
            let successfulCount = Set(mediaResults.map(\.sourceName)).count
            statusMessage = mediaResults.isEmpty ? "没有找到影片，可通过站源筛选查看各站状态。" : "找到 \(mediaResults.count) 条结果，来自 \(successfulCount) 个站点"
        } catch { mediaResults = []; statusMessage = "影片搜索失败：\(error.localizedDescription)" }
    }

    @MainActor
    private func loadMovieDetail(_ item: TVMediaItem) async throws -> TVMediaItem {
        guard item.spiderSite != nil else { return item }
        let detail = try await SourceLoader().loadSpiderDetail(item: item, baseURL: spiderService.baseURL, token: spiderService.token)
        if let index = mediaResults.firstIndex(where: { $0.id == item.id }) { mediaResults[index] = detail }
        return detail
    }

    @MainActor
    private func playMedia(item: TVMediaItem, source: TVPlaySource, failedSources: Set<TVPlaySource> = [], recoveryNotice: String? = nil) {
        playbackTask?.cancel()
        playbackMovie = item
        playbackSource = source
        playbackNotice = "正在解析：\(source.flag ?? source.name)"
        statusMessage = "正在解析《\(item.name)》· \(source.name)…"
        // 统一由播放入口关闭详情弹窗，避免其他调用路径遗漏 dismiss，
        // 也确保切到播放器页后错误提示不会继续被 sheet 遮挡。
        selectedMovie = nil
        // 先切到播放器页，让解析中的状态和失败原因始终可见；详情弹窗关闭后，
        // 不会再把错误只留在影视页底部的状态栏里。
        selectedSection = .player
        playback.stop()
        playback.clearError()
        playbackTask = Task {
            do {
                let selection = try await PlaybackRouteResolver.resolve(source: source, sources: item.playSources.filter { !failedSources.contains($0) }) { candidate in
                    try Task.checkCancellation()
                    playbackNotice = "正在解析：\(candidate.flag ?? candidate.name)"
                    let result = try await SourceLoader().resolvePlayback(item: item, source: candidate, baseURL: spiderService.baseURL, token: spiderService.token)
                    var url = result.url
                    if item.spiderSite != nil { url = try await spiderService.preparePlaybackURL(url) }
                    return ResolvedMediaPlayback(url: url, headers: result.headers, isDirect: result.isDirect)
                }
                try Task.checkCancellation()
                playbackSource = selection.source
                let resolved = selection.playback
                let playbackURL = resolved.url
                playbackNotice = selection.notice ?? recoveryNotice ?? "\(item.name) · \(selection.source.flag ?? selection.source.name)"
                if resolved.isDirect {
                    playback.play(TVChannel(id: item.id + resolved.url.absoluteString, name: item.name, group: "\(item.sourceName) · \(selection.source.name)", logoURL: item.posterURL, streamURL: playbackURL, headers: resolved.headers)) {
                        // 仅启动失败时换源，最多切换两次；用户手动选集会开始新一轮。
                        guard playbackMovie?.id == item.id, playbackSource == selection.source, failedSources.count < 2 else { return }
                        let failed = failedSources.union([source, selection.source])
                        let alternatives = PlaybackRouteResolver.alternatives(for: selection.source, in: item.playSources)
                        guard let next = alternatives.first(where: { !failed.contains($0) }) else { return }
                        playMedia(item: item, source: next, failedSources: failed,
                                  recoveryNotice: "\(selection.source.routeName)无法打开，已切换到\(next.routeName) · \(next.episodeName)")
                    }
                    selectedSection = .player
                    statusMessage = "正在播放《\(item.name)》· \(item.sourceName) · \(selection.source.name)"
                } else {
                    playback.openWeb(playbackURL)
                    selectedSection = .player
                    statusMessage = "正在打开《\(item.name)》的播放页"
                }
            } catch {
                guard !Task.isCancelled else { return }
                playbackNotice = "\(item.name) · \(source.flag ?? source.name)"
                let message = "播放解析失败：\(error.localizedDescription)"
                statusMessage = message
                // Spider 的授权、解析器等错误发生在 AVPlayer 创建前，不能依赖
                // PlaybackCoordinator.play(_:) 的 KVO 错误回调来展示。
                playback.showError(message)
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
                if selectedSection == .player { sidebarButton(.player) }
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
    let isSearching: Bool
    let search: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.title2.bold()); Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索影片、频道或分组", text: $searchText, onCommit: search).textFieldStyle(.plain).frame(width: 250)
                if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Button(isSearching ? "搜索中…" : "搜索", action: search).buttonStyle(.borderedProminent).controlSize(.small).disabled(isSearching || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            Spacer(); VStack(spacing: 8) { Button(action: play) { Image(systemName: "play.fill") }.buttonStyle(.borderedProminent).controlSize(.small); Button(action: toggleFavorite) { Image(systemName: isFavorite ? "star.fill" : "star") }.buttonStyle(.plain).foregroundStyle(isFavorite ? .yellow : .secondary) }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MovieCard: View {
    let item: TVMediaItem; let openDetail: () -> Void; let play: (TVPlaySource) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: item.posterURL) { phase in
                    switch phase { case .success(let image): image.resizable().scaledToFill(); default: ZStack { Color.secondary.opacity(0.14); Image(systemName: "film").font(.title).foregroundStyle(.secondary) } }
                }.frame(maxWidth: .infinity).aspectRatio(0.68, contentMode: .fit).clipped().background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                if let remark = item.remark, !remark.isEmpty { Text(remark).font(.caption2).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white).padding(7) }
            }
            Text(item.name).font(.body.weight(.semibold)).lineLimit(2); Text(item.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

private struct MovieDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var detail: TVMediaItem
    @State private var isLoading = false
    @State private var errorMessage: String?
    let loadDetail: (TVMediaItem) async throws -> TVMediaItem
    let play: (TVMediaItem, TVPlaySource) -> Void

    init(item: TVMediaItem, loadDetail: @escaping (TVMediaItem) async throws -> TVMediaItem,
         play: @escaping (TVMediaItem, TVPlaySource) -> Void) {
        _detail = State(initialValue: item)
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
                    if let remark = detail.remark, !remark.isEmpty { Text(remark).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            Divider()
            if isLoading {
                ProgressView("正在加载详情…").frame(maxWidth: .infinity, minHeight: 100)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Label("详情加载失败：\(errorMessage)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("重试") { Task { await loadIfNeeded(force: true) } }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, minHeight: 100)
            } else if detail.playSources.isEmpty {
                Text("站点未返回可播放线路").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                Text("播放线路").font(.headline)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(detail.playSources.enumerated()), id: \.offset) { _, source in
                            Button { play(detail, source) } label: {
                                HStack { Text(source.name); Spacer(); Image(systemName: "play.fill") }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .task { await loadIfNeeded() }
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

    @MainActor
    private func loadIfNeeded(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || (detail.playSources.isEmpty && detail.spiderSite != nil) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { detail = try await loadDetail(detail) }
        catch { errorMessage = error.localizedDescription }
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
