import XCTest
@testable import TVBoxMacOS

final class CMSCompatibilityTests: XCTestCase {
    func testCMSParsesMultipleRoutesAndEpisodesWithoutCorruptingURLs() throws {
        let site = TVBoxSite(key: "demo", name: "Demo", api: URL(string: "https://example.com/api.php")!)
        let data = Data(#"{"list":[{"vod_id":"1","vod_name":"Movie","vod_play_from":"线路A$$$线路B","vod_play_url":"第1集$https://a.example/1.m3u8#第2集$https://a.example/2.m3u8$$$第1集$https://b.example/1.m3u8"}]}"#.utf8)
        let result = try XCTUnwrap(TVBoxSearchParser.parse(data: data, site: site).first)
        XCTAssertEqual(result.playSources.map(\.name), ["线路A · 第1集", "线路A · 第2集", "线路B · 第1集"])
        XCTAssertEqual(result.playSources.map(\.url?.absoluteString), ["https://a.example/1.m3u8", "https://a.example/2.m3u8", "https://b.example/1.m3u8"])
    }

    func testCMSRequestsReplaceOperationParametersAndKeepAuthentication() throws {
        let site = TVBoxSite(key: "demo", name: "Demo", api: URL(string: "https://example.com/api.php?ac=list&ac=old&wd=old&ids=99&token=secret")!)
        let search = try XCTUnwrap(TVBoxSearchParser.makeSearchURL(site: site, keyword: " 蜘蛛侠 "))
        let query = try XCTUnwrap(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.filter { $0.name == "ac" }.map(\.value), ["detail"])
        XCTAssertEqual(query.filter { $0.name == "wd" }.map(\.value), ["蜘蛛侠"])
        XCTAssertFalse(query.contains { $0.name == "ids" })
        XCTAssertEqual(query.first { $0.name == "token" }?.value, "secret")
        let detail = try XCTUnwrap(TVBoxSearchParser.makeDetailURL(site: site, id: "7"))
        let detailQuery = try XCTUnwrap(URLComponents(url: detail, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(detailQuery.filter { $0.name == "ac" }.map(\.value), ["detail"])
        XCTAssertEqual(detailQuery.filter { $0.name == "ids" }.map(\.value), ["7"])
        XCTAssertFalse(detailQuery.contains { $0.name == "wd" })
    }

    func testCatalogKeepsScriptSitesButDoesNotExposeThemAsCMS() throws {
        let data = Data(#"{"sites":[{"key":"js","name":"JS","type":1,"api":"https://example.com/drpy.js?x=1"},{"key":"type3","name":"Script","type":3,"api":"https://example.com/engine"},{"key":"cms","name":"CMS","type":1,"api":"https://example.com/api.php"}]}"#.utf8)
        let catalog = try TVBoxJSONAdapter().parseCatalog(data: data)
        XCTAssertEqual(catalog.count, 3)
        XCTAssertNil(catalog[0].api)
        XCTAssertEqual(catalog[0].adapter, "https://example.com/drpy.js?x=1")
        XCTAssertNil(catalog[1].api)
        XCTAssertNotNil(catalog[2].api)
    }

    func testLocalCatalogAndMovieOnlyImportAreSupported() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(#"{"sites":[{"key":"cms","name":"CMS","api":"https://example.com/api.php"}]}"#.utf8).write(to: fileURL)
        let catalog = try await SourceLoader().loadCatalog(url: fileURL)
        XCTAssertEqual(catalog.first?.key, "cms")
        let snapshot = try SourceLoader().load(fileURL: fileURL)
        XCTAssertEqual(snapshot.source.kind, .tvboxJSON)
        XCTAssertTrue(snapshot.channels.isEmpty)
    }

    func testMediaIDsIncludeEndpointNamespace() throws {
        let data = Data(#"{"list":[{"vod_id":1,"vod_name":"Movie"}]}"#.utf8)
        let first = TVBoxSite(key: "cms", name: "CMS", api: URL(string: "https://a.example/api.php")!)
        let second = TVBoxSite(key: "cms", name: "CMS", api: URL(string: "https://b.example/api.php")!)
        let firstItem = try XCTUnwrap(TVBoxSearchParser.parse(data: data, site: first).first)
        let secondItem = try XCTUnwrap(TVBoxSearchParser.parse(data: data, site: second).first)
        XCTAssertNotEqual(firstItem.id, secondItem.id)
        XCTAssertEqual(firstItem.siteKey, "cms")
    }

    func testDetailEnrichmentPreservesOrderCapsConcurrencyAndRequiresMatchingID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CMSFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        CMSFixtureProtocol.reset()
        let site = TVBoxSite(key: "cms", name: "CMS", api: URL(string: "https://fixture.example/api.php")!)
        let results = try await SourceLoader(session: session).search(site: site, keyword: "Movie")
        XCTAssertEqual(results.map(\.name), (0..<9).map { "Movie \($0)" })
        XCTAssertTrue(results[2].playSources.isEmpty, "A different movie with the same name must not supply playback sources")
        XCTAssertTrue(results.enumerated().filter { $0.offset != 2 }.allSatisfy { !$0.element.playSources.isEmpty })
        XCTAssertLessThanOrEqual(CMSFixtureProtocol.maximumActive, 4)
        XCTAssertTrue(CMSFixtureProtocol.hadBrowserHeaders)
    }
}

/// 模拟摘要型 CMS，并故意乱序完成详情，验证并发上限与 ID 匹配。
private final class CMSFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var active = 0
    private static var maximum = 0
    private static var validHeaders = true
    static var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    static var hadBrowserHeaders: Bool { lock.lock(); defer { lock.unlock() }; return validHeaders }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        active = 0; maximum = 0; validHeaders = true
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = items.first { $0.name == "ids" }?.value.flatMap(Int.init)
        Self.lock.lock()
        Self.validHeaders = Self.validHeaders && request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") == true && request.value(forHTTPHeaderField: "Accept") != nil
        if id != nil { Self.active += 1; Self.maximum = max(Self.maximum, Self.active) }
        Self.lock.unlock()
        let rows: [[String: Any]]
        if let id {
            rows = [["vod_id": id == 2 ? 99 : id, "vod_name": "Movie \(id)", "vod_play_url": "正片$https://example.com/\(id).m3u8"]]
        } else {
            rows = (0..<9).map { ["vod_id": $0, "vod_name": "Movie \($0)"] }
        }
        let data = try! JSONSerialization.data(withJSONObject: ["list": rows])
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(4 - ((id ?? 0) % 4)) * 0.01) { [self] in
            if id != nil { Self.lock.lock(); Self.active -= 1; Self.lock.unlock() }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
