import XCTest
@testable import TVBoxMacOS

final class MovieFavoritesStoreTests: XCTestCase {
    /// 收藏往返必须保留站源、影片 ID 与线路，且同名不同站点不会相互覆盖。
    @MainActor
    func testPersistsProviderMetadataAndRemovesByStableIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("favorites.json")
        let store = MovieFavoritesStore(fileURL: file)
        let site = TVBoxSite(key: "provider", name: "站点", adapter: "csp_Test",
                             spiderURL: URL(string: "https://example.com/spider.jar"), spiderExt: "config")
        let first = TVMediaItem(id: "provider:1", name: "同名影片",
                                playSources: [TVPlaySource(name: "线路 · 第01集", playerID: "episode", flag: "线路")],
                                siteKey: site.key, spiderSite: site, vodID: "1")
        let second = TVMediaItem(id: "other:1", name: first.name)
        store.toggle(first)
        store.toggle(second)
        await store.waitForPendingChanges()
        let restored = MovieFavoritesStore(fileURL: file)
        await restored.waitForPendingChanges()
        XCTAssertEqual(restored.items, [second, first])
        var detail = first
        detail.remark = "已更新"
        XCTAssertTrue(restored.contains(detail))
        restored.refresh(detail)
        await restored.waitForPendingChanges()
        let refreshed = MovieFavoritesStore(fileURL: file)
        await refreshed.waitForPendingChanges()
        XCTAssertEqual(refreshed.items.last, detail)
        restored.toggle(detail)
        await restored.waitForPendingChanges()
        let removed = MovieFavoritesStore(fileURL: file)
        await removed.waitForPendingChanges()
        XCTAssertEqual(removed.items, [second])
    }

    /// 读取损坏文件时禁止覆盖，避免一次收藏操作清空用户原有数据。
    @MainActor
    func testCorruptFileIsPreserved() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("invalid json".utf8)
        try data.write(to: file)
        let store = MovieFavoritesStore(fileURL: file)
        store.toggle(TVMediaItem(id: "one", name: "影片"))
        await store.waitForPendingChanges()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    /// 无法落盘时不发布虚假的收藏成功状态。
    @MainActor
    func testFailedWriteDoesNotChangePublishedFavorites() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data().write(to: parent)
        let store = MovieFavoritesStore(fileURL: parent.appendingPathComponent("favorites.json"))
        store.toggle(TVMediaItem(id: "one", name: "影片"))
        await store.waitForPendingChanges()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    /// 多次快速操作必须按提交顺序执行，不能都基于尚未更新的 UI 快照计算。
    @MainActor
    func testQueuedChangesUseLatestPersistedState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MovieFavoritesStore(fileURL: folder.appendingPathComponent("favorites.json"))
        let first = TVMediaItem(id: "one", name: "甲")
        let second = TVMediaItem(id: "two", name: "乙")
        store.toggle(first)
        store.toggle(second)
        store.toggle(first)
        var updated = second
        updated.remark = "新剧集"
        store.refresh(updated)
        XCTAssertTrue(store.isSaving)
        await store.waitForPendingChanges()
        XCTAssertEqual(store.items, [updated])
        XCTAssertFalse(store.isSaving)
    }

    /// 已存在的旧收藏先读取，再接收启动期间提交的新增操作。
    @MainActor
    func testMutationDuringInitialLoadPreservesExistingFavorites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("favorites.json")
        let existing = TVMediaItem(id: "old", name: "已有收藏")
        try JSONEncoder().encode([existing]).write(to: file)
        let store = MovieFavoritesStore(fileURL: file)
        let added = TVMediaItem(id: "new", name: "新增收藏")
        store.toggle(added)
        await store.waitForPendingChanges()
        XCTAssertEqual(store.items, [added, existing])
    }

    /// 旧身份详情与新搜索结果匹配时，刷新替换快照并持久化新的订阅身份。
    @MainActor
    func testRefreshMigratesLegacyFavoriteIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("favorites.json")
        let store = MovieFavoritesStore(fileURL: file)
        let old = TVMediaItem(id: "legacy", name: "影片", sourceName: "站点", siteKey: "site")
        store.toggle(old)
        let fresh = TVMediaItem(id: "new", name: old.name, remark: "更新", sourceName: old.sourceName,
                                siteKey: old.siteKey, sourceNamespace: "subscription", legacyID: old.id)
        store.refresh(fresh)
        await store.waitForPendingChanges()
        XCTAssertEqual(store.items, [fresh])
        XCTAssertTrue(store.contains(old))
        let restored = MovieFavoritesStore(fileURL: file)
        await restored.waitForPendingChanges()
        XCTAssertEqual(restored.items, [fresh])
    }
}
