import XCTest
@testable import TVBoxMacOS

@MainActor
final class MovieDetailModelTests: XCTestCase {
    /// 已有线路仍会在每次进入详情时刷新，过期链接和新增剧集可被替换。
    func testExistingPlaybackSourcesAreRefreshed() async {
        let old = fixture()
        let model = MovieDetailModel(item: old)
        var calls = 0
        await model.refresh { item in
            calls += 1
            var fresh = item
            fresh.playSources.append(TVPlaySource(name: "第 2 集", url: URL(string: "https://example.com/new.mp4")))
            return fresh
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.item.playSources.count, 2)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    /// 远程详情失败后保留缓存线路，并允许后续重试成功清除错误。
    func testFailurePreservesSnapshotAndRetryCanReplaceIt() async {
        let old = fixture()
        let model = MovieDetailModel(item: old)
        await model.refresh { _ in throw URLError(.timedOut) }
        XCTAssertEqual(model.item, old)
        XCTAssertNotNil(model.errorMessage)
        await model.refresh { item in
            var fresh = item
            fresh.remark = "更新"
            return fresh
        }
        XCTAssertEqual(model.item.remark, "更新")
        XCTAssertNil(model.errorMessage)
    }

    /// 选择其他站点后，先前未完成的详情不能覆盖新影片。
    func testLateResponseDoesNotOverwriteNewSelection() async {
        let old = fixture()
        let model = MovieDetailModel(item: old)
        let second = TVMediaItem(id: "other", name: "另一影片")
        await model.refresh { item in
            model.select(second)
            return item
        }
        XCTAssertEqual(model.item.id, second.id)
        XCTAssertFalse(model.isLoading)
    }

    /// 收藏卡片直接选集时替换过期地址，不能按数组下标误播新增或重排后的剧集。
    func testRefreshMatchesEpisodeAndRejectsAmbiguousSources() {
        let old = TVPlaySource(name: "线路 · 第 1 集", url: URL(string: "https://example.com/expired"))
        let fresh = TVPlaySource(name: old.name, url: URL(string: "https://example.com/renewed"))
        var item = fixture()
        item.playSources = [TVPlaySource(name: "线路 · 第 2 集"), fresh]
        XCTAssertEqual(MovieApplicationService.refreshedSource(old, in: item), fresh)
        item.playSources.append(fresh)
        XCTAssertNil(MovieApplicationService.refreshedSource(old, in: item))
    }

    /// 可用的 CMS 详情地址与旧播放线路用于回归缓存刷新策略。
    private func fixture() -> TVMediaItem {
        TVMediaItem(id: "one", name: "影片", detailURL: URL(string: "https://example.com/detail"),
                    playSources: [TVPlaySource(name: "第 1 集", url: URL(string: "https://example.com/old.mp4"))],
                    siteKey: "cms", vodID: "one")
    }
}
