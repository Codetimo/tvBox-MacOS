import Combine
import Foundation

/// 收藏影片保留站源身份和详情入口；发布状态只代表已成功落盘的数据。
@MainActor
final class MovieFavoritesStore: ObservableObject {
    @Published private(set) var items: [TVMediaItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSaving = false
    private let persistence: MovieFavoritesPersistence
    private var pendingCount = 0
    private var pendingTask: Task<Void, Never>?

    /// 文件加载移出主线程；后续操作自动排在初始读取之后，避免启动时覆盖已有收藏。
    init(fileURL: URL? = nil) {
        persistence = MovieFavoritesPersistence(fileURL: fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TVBoxMacOS/movie-favorites.json"))
        enqueue(nil)
    }

    /// 新旧身份兼容匹配允许收藏在详情刷新后逐步迁移，同时保留不同站源的同名影片。
    func contains(_ item: TVMediaItem) -> Bool {
        items.contains { $0.matchesFavorite(item) }
    }

    /// 按调用顺序提交切换操作；每个操作基于前一次成功持久化结果计算。
    func toggle(_ item: TVMediaItem) { enqueue(.toggle(item)) }

    /// 成功获取新详情后更新已收藏快照，不会将尚未收藏的影片自动加入。
    func refresh(_ item: TVMediaItem) { enqueue(.refresh(item)) }

    /// 等待已提交的存储操作，供测试和需要持久化完成保证的调用方使用。
    func waitForPendingChanges() async { await pendingTask?.value }

    /// 独立任务链不会随 View 的 task 取消；磁盘事务由 actor 执行，返回后按顺序更新界面。
    private func enqueue(_ mutation: MovieFavoritesPersistence.Mutation?) {
        let previous = pendingTask
        pendingCount += 1
        isSaving = true
        pendingTask = Task {
            await previous?.value
            do {
                items = try await persistence.apply(mutation)
                errorMessage = nil
            } catch {
                errorMessage = "影片收藏读写失败，原有收藏已保留：\(error.localizedDescription)"
            }
            pendingCount -= 1
            isSaving = pendingCount > 0
        }
    }
}

/// 整个读改写事务不包含 await，磁盘 I/O 和 JSON 编解码不会占用 UI 主线程。
private actor MovieFavoritesPersistence {
    enum Mutation { case toggle(TVMediaItem), refresh(TVMediaItem) }
    private let fileURL: URL

    /// 路径注入使持久化错误与快速连续操作能够独立测试。
    init(fileURL: URL) { self.fileURL = fileURL }

    /// 先读当前文件，再计算更新并原子保存；损坏文件不能被空收藏覆盖。
    func apply(_ mutation: Mutation?) throws -> [TVMediaItem] {
        var items: [TVMediaItem] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoded = try JSONDecoder().decode([TVMediaItem].self, from: Data(contentsOf: fileURL))
            var seen = Set<String>()
            items = decoded.filter { seen.insert($0.id).inserted }
        }
        guard let mutation else { return items }
        let original = items
        switch mutation {
        case .toggle(let item):
            if let index = items.firstIndex(where: { $0.matchesFavorite(item) }) { items.remove(at: index) }
            else { items.insert(item, at: 0) }
        case .refresh(let item):
            guard let index = items.firstIndex(where: { $0.matchesFavorite(item) }) else { return items }
            items[index] = item
        }
        guard items != original else { return items }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
        return items
    }
}
