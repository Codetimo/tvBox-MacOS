import XCTest
@testable import TVBoxMacOS

final class SearchProviderStateTests: XCTestCase {
    /// 同名站点的成功与失败状态、结果归属必须彼此独立。
    func testSameNameSitesKeepIndependentResultsAndStatus() throws {
        let firstSource = TVSource(name: "订阅 A", location: URL(string: "https://a.invalid/config")!, kind: .tvboxJSON)
        let secondSource = TVSource(name: "订阅 B", location: URL(string: "https://b.invalid/config")!, kind: .tvboxJSON)
        var first = TVBoxSite(key: "shared", name: "同名站", api: URL(string: "https://fixture.invalid/api")!)
        var second = first
        first.sourceNamespace = firstSource.id.uuidString
        second.sourceNamespace = secondSource.id.uuidString
        let response = Data(#"{"list":[{"vod_id":"1","vod_name":"影片"}]}"#.utf8)
        let items = try TVBoxSearchParser.parse(data: response, site: first)
        var state = SearchProviderState()
        state.catalog([first], source: firstSource)
        state.catalog([second], source: secondSource)
        state.result(.success(items), site: first)
        state.result(.failure(URLError(.timedOut)), site: second)
        XCTAssertEqual(state.providers.count, 2)
        XCTAssertEqual(state.providerID(for: items[0]), first.id)
        XCTAssertEqual(state.provider(id: first.id)?.status, "1 条结果")
        XCTAssertTrue(state.provider(id: second.id)?.status.hasPrefix("查询失败") == true)
        XCTAssertEqual(Set(state.providers.map { state.label(for: $0) }), ["同名站 · 订阅 A", "同名站 · 订阅 B"])
    }

    /// 同名订阅也能区分，公开目录和配置读取失败不会覆盖已有站点。
    func testCatalogFailureAndFallbackDoNotOverwriteSameNameProvider() {
        let source = TVSource(name: "公开检索", location: URL(string: "https://fixture.invalid/config")!, kind: .tvboxJSON)
        let site = TVBoxSite(key: "provider", name: "公开检索", api: URL(string: "https://fixture.invalid/api")!)
        let item = TVMediaItem(id: "360:1", name: "公开影片")
        var state = SearchProviderState()
        state.catalog([site], source: source)
        state.catalogFailed(source)
        state.fallback([item])
        XCTAssertEqual(state.providers.count, 3)
        XCTAssertEqual(Set(state.providers.map { state.label(for: $0) }).count, 3)
        XCTAssertEqual(state.providerID(for: item), "public")
        XCTAssertEqual(state.provider(id: site.id)?.status, "等待查询…")
        XCTAssertEqual(state.provider(id: "public")?.status, "1 条结果（第三方目录）")
    }
}
