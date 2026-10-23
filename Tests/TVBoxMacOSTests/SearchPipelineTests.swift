import XCTest
@testable import TVBoxMacOS

final class SearchPipelineTests: XCTestCase {
    /// 后续 CMS 不等同批慢站点、慢目录或 Spider；普通搜索站点也必须被调用。
    @MainActor func testSchedulesAcrossCatalogsAndRefillsBeforeSlowSiteFinishes() async {
        let fixture = SearchFixture()
        let first = TVSource(name: "fast", location: URL(string: "https://fixture.invalid/fast")!, kind: .tvboxJSON)
        let second = TVSource(name: "slow", location: URL(string: "https://fixture.invalid/slow")!, kind: .tvboxJSON)
        await SearchPipeline.run(sources: [first, second], siteLimit: 2, loadCatalog: { source in
            if source.name == "slow" { try await Task.sleep(nanoseconds: 250_000_000); await fixture.record("slowCatalog"); return [] }
            return [Self.site("slow"), Self.site("fast1"), Self.site("fast2"),
                    TVBoxSite(key: "ordinary", name: "ordinary", adapter: "csp_Demo", quickSearch: false)]
        }, search: { try await fixture.search($0) }, receive: { _ in })
        let events = await fixture.events
        XCTAssertLessThan(events.firstIndex(of: "finish-fast2")!, events.firstIndex(of: "finish-slow")!)
        XCTAssertLessThan(events.firstIndex(of: "finish-fast2")!, events.firstIndex(of: "slowCatalog")!)
        XCTAssertTrue(events.contains("start-ordinary"))
        let maximumCMS = await fixture.maximumCMS
        XCTAssertLessThanOrEqual(maximumCMS, 2)
    }

    /// 取消后不派发剩余站点，也不交付失败/过时结果。
    @MainActor func testCancellationStopsQueuedSitesAndResultDelivery() async {
        let started = expectation(description: "request started")
        let fixture = SearchFixture()
        let source = TVSource(name: "source", location: URL(string: "https://fixture.invalid/config")!, kind: .tvboxJSON)
        var delivered = 0
        let task = Task {
            await SearchPipeline.run(sources: [source], siteLimit: 1, loadCatalog: { _ in
                (0..<10).map { Self.site("site-\($0)") }
            }, search: { site in
                await fixture.record(site.key)
                started.fulfill()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return []
            }, receive: { event in if case .result = event { delivered += 1 } })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await task.value
        let events = await fixture.events
        XCTAssertEqual(events, ["site-0"])
        XCTAssertEqual(delivered, 0)
    }

    private static func site(_ name: String) -> TVBoxSite {
        TVBoxSite(key: name, name: name, api: URL(string: "https://fixture.invalid/\(name)")!)
    }
}

private actor SearchFixture {
    var events: [String] = []
    var maximumCMS = 0
    private var activeCMS = 0

    func record(_ event: String) { events.append(event) }

    /// 模拟不同站点耗时并记录真实并发数，避免只验证调度函数内部实现。
    func search(_ site: TVBoxSite) async throws -> [TVMediaItem] {
        events.append("start-\(site.key)")
        if !site.usesSpider { activeCMS += 1; maximumCMS = max(maximumCMS, activeCMS) }
        defer { if !site.usesSpider { activeCMS -= 1 } }
        try await Task.sleep(nanoseconds: site.key == "slow" || site.usesSpider ? 200_000_000 : 5_000_000)
        events.append("finish-\(site.key)")
        return []
    }
}
