import XCTest
@testable import TVBoxMacOS

final class SourceAdapterTests: XCTestCase {
    func testPanCookieExtensionPreservesSourceConfiguration() throws {
        let ext = PanCookieStore.spiderExtension(base: #"{"token":"source"}"#, quark: "q=1", baidu: "b=2")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ext.utf8)) as? [String: Any])
        XCTAssertEqual(object["token"] as? String, "source")
        XCTAssertEqual(object["quark_cookie"] as? String, "q=1")
        XCTAssertEqual(object["baidu_cookie"] as? String, "b=2")
    }
    func testPanCookieAuthenticationIgnoresVisitorCookieAndRejectsLookalikeDomain() throws {
        let visitor = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "baidu.com", .path: "/", .name: "BAIDUID", .value: "visitor"
        ]))
        XCTAssertNil(PanCookieStore.authenticatedHeader(cookies: [visitor], provider: .baidu))
        let lookalike = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "evilbaidu.com", .path: "/", .name: "BDUSS", .value: "fake"
        ]))
        XCTAssertNil(PanCookieStore.authenticatedHeader(cookies: [lookalike], provider: .baidu))
    }

    func testPanCookieExtensionPreservesOpaqueNonJSONValue() {
        let ext = PanCookieStore.spiderExtension(base: "opaque-extension", quark: "q=1", baidu: nil)
        XCTAssertEqual(ext, "opaque-extension")
    }

    func testPanCookiesAcceptOfficialIdentityAndRejectExpiredIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (provider, name, domain) in [(PanCookieStore.Provider.quark, "__puus", ".quark.cn"), (.baidu, "BDUSS", ".baidu.com")] {
            let valid = try XCTUnwrap(HTTPCookie(properties: [
                .domain: domain, .path: "/", .name: name, .value: "account", .expires: now.addingTimeInterval(60)
            ]))
            let expired = try XCTUnwrap(HTTPCookie(properties: [
                .domain: domain, .path: "/", .name: name, .value: "old", .expires: now.addingTimeInterval(-60)
            ]))
            XCTAssertEqual(PanCookieStore.authenticatedHeader(cookies: [valid], provider: provider, now: now), "\(name)=account")
            XCTAssertNil(PanCookieStore.authenticatedHeader(cookies: [expired], provider: provider, now: now))
        }
    }

    func testPanLogoutClearsManagedAliasesButPreservesOtherSourceSettings() throws {
        let base = #"{"quark_cookie":"old","quarkCookie":"old","baidu_cookie":"source-managed","token":"source"}"#
        let ext = PanCookieStore.spiderExtension(base: base, quark: "", baidu: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ext.utf8)) as? [String: String])
        XCTAssertEqual(object["quark_cookie"], "")
        XCTAssertEqual(object["quarkCookie"], "")
        XCTAssertEqual(object["baidu_cookie"], "source-managed")
        XCTAssertEqual(object["token"], "source")
    }

    func testSearchRelevanceKeepsExactAndPrefixMatchesAheadOfLateBroadMatches() {
        let exact = TVBoxSearchParser.searchRelevanceScore(name: "人之下", keyword: "人之下")
        let prefix = TVBoxSearchParser.searchRelevanceScore(name: "人之下 第二季", keyword: "人之下")
        let broad = TVBoxSearchParser.searchRelevanceScore(name: "我在人之下", keyword: "人之下")
        let unrelated = TVBoxSearchParser.searchRelevanceScore(name: "另一部影片", keyword: "人之下")
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, broad)
        XCTAssertGreaterThan(broad, unrelated)
    }

    func testM3UParsesChannelAndGroup() throws {
        let source = TVSource(name: "fixture", location: URL(string: "https://example.com/live.m3u")!, kind: .m3u)
        let data = Data("#EXTM3U\n#EXTINF:-1 tvg-name=\"News\" group-title=\"News\",News HD\nhttps://example.com/news.m3u8\n".utf8)
        let snapshot = try M3UAdapter().parse(data: data, source: source)
        XCTAssertEqual(snapshot.channels.count, 1)
        XCTAssertEqual(snapshot.channels[0].group, "News")
        XCTAssertEqual(snapshot.channels[0].name, "News HD")
    }

    func testParsedChannelsHaveDistinctStableIDs() throws {
        let source = TVSource(name: "fixture", location: URL(string: "https://example.com/live.m3u")!, kind: .m3u)
        let data = Data("#EXTM3U\n#EXTINF:-1,One\nhttps://example.com/one\n#EXTINF:-1,Two\nhttps://example.com/two\n".utf8)
        let channels = try M3UAdapter().parse(data: data, source: source).channels
        XCTAssertEqual(Set(channels.map(\.id)).count, 2)
    }

    func testM3UParsesBOMHeadersAndSkipsUnsupportedURLs() throws {
        let source = TVSource(name: "fixture", location: URL(string: "https://example.com/live.m3u")!, kind: .m3u)
        let data = Data("\u{feff}#EXTM3U\n#EXTINF:-1 group-title=\"News\" http-user-agent=\"Fixture\",News\nhttps://example.com/news.m3u8\n#EXTINF:-1 group-title=\"News\",Unsupported\nrtmp://example.com/live\n".utf8)
        let snapshot = try M3UAdapter().parse(data: data, source: source)
        XCTAssertEqual(snapshot.channels.count, 1)
        XCTAssertEqual(snapshot.channels[0].headers["User-Agent"], "Fixture")
    }

    func testTVBoxJSONParsesAllURLs() throws {
        let source = TVSource(name: "fixture", location: URL(string: "https://example.com/source.json")!, kind: .tvboxJSON)
        let data = Data("{\"lives\":[{\"name\":\"CCTV\",\"urls\":[\"https://a.example/live\",\"https://b.example/live\"]}]}".utf8)
        let snapshot = try TVBoxJSONAdapter().parse(data: data, source: source)
        XCTAssertEqual(snapshot.channels.map(\.streamURL.absoluteString), ["https://a.example/live", "https://b.example/live"])
    }

    func testM3UDeduplicatesRepeatedStreamURLs() throws {
        let source = TVSource(name: "fixture", location: URL(string: "https://example.com/live.m3u")!, kind: .m3u)
        let data = Data("#EXTM3U\n#EXTINF:-1 group-title=\"News\",News\nhttps://example.com/a\n#EXTINF:-1 group-title=\"News\",News duplicate\nhttps://example.com/a\n".utf8)
        let snapshot = try M3UAdapter().parse(data: data, source: source)
        XCTAssertEqual(snapshot.channels.count, 1)
    }

    func testTVBoxCatalogAndSearchResponse() throws {
        let catalog = try TVBoxJSONAdapter().parseCatalog(data: Data("{\"sites\":[{\"key\":\"demo\",\"name\":\"Demo\",\"api\":\"https://example.com/api.php\",\"searchable\":1}]}".utf8))
        XCTAssertEqual(catalog.first?.key, "demo")
        let site = try XCTUnwrap(catalog.first)
        let response = Data("{\"list\":[{\"vod_id\":\"1\",\"vod_name\":\"Movie\",\"vod_play_url\":\"线路$https://example.com/play.m3u8\"}]}".utf8)
        let results = try TVBoxSearchParser.parse(data: response, site: site)
        XCTAssertEqual(results.first?.playSources.first?.url?.absoluteString, "https://example.com/play.m3u8")
        XCTAssertEqual(results.first?.sourceName, "Demo")
        XCTAssertEqual(results.first?.siteKey, "demo")
        XCTAssertEqual(results.first?.detailURL?.absoluteString, "https://example.com/api.php?ac=detail&ids=1")
    }

    func testCatalogCacheReusesDirectoryUntilSourceIsInvalidated() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVBoxMacOS-catalog-\(UUID().uuidString).json")
        defer {
            SourceLoader.invalidateCatalog(url: fileURL)
            try? FileManager.default.removeItem(at: fileURL)
        }
        try Data(#"{"sites":[{"key":"first","name":"First","api":"https://example.com/api.php"}]}"#.utf8)
            .write(to: fileURL)

        let loader = SourceLoader()
        let firstCatalog = try await loader.loadCatalog(url: fileURL)
        XCTAssertEqual(firstCatalog.first?.key, "first")

        try Data(#"{"sites":[{"key":"second","name":"Second","api":"https://example.com/api.php"}]}"#.utf8)
            .write(to: fileURL)
        // 未显式失效时复用启动预热得到的目录，避免搜索再次读取同一文件/远程 URL。
        let cachedCatalog = try await loader.loadCatalog(url: fileURL)
        XCTAssertEqual(cachedCatalog.first?.key, "first")

        SourceLoader.invalidateCatalog(url: fileURL)
        let refreshedCatalog = try await loader.loadCatalog(url: fileURL)
        XCTAssertEqual(refreshedCatalog.first?.key, "second")
    }

    func testCMSParserAcceptsNumericVodID() throws {
        let site = TVBoxSite(key: "ik", name: "IK", api: URL(string: "https://example.com/api.php")!)
        let response = Data("{\"list\":[{\"vod_id\":123,\"vod_name\":\"Movie\",\"vod_play_url\":\"正片$https://example.com/movie.m3u8\"}]}".utf8)
        let result = try TVBoxSearchParser.parse(data: response, site: site)
        XCTAssertEqual(result.first?.id, "https://example.com/api.php|ik|123")
        XCTAssertEqual(result.first?.playSources.count, 1)
    }

    func testTVBoxCatalogKeepsSpiderSiteNames() throws {
        let catalog = try TVBoxJSONAdapter().parseCatalog(data: Data("{\"spider\":\"http://oss4liview.moji.com/spider.jpg;md5;abc123\",\"sites\":[{\"key\":\"huBan\",\"name\":\"虎斑 4K\",\"api\":\"csp_AiNewHuBanGuard\",\"searchable\":1}]}".utf8))
        XCTAssertEqual(catalog.first?.name, "虎斑 4K")
        XCTAssertEqual(catalog.first?.adapter, "csp_AiNewHuBanGuard")
        XCTAssertNil(catalog.first?.api)
        XCTAssertEqual(catalog.first?.spiderURL?.absoluteString, "http://oss4liview.moji.com/spider.jpg")
        XCTAssertEqual(catalog.first?.spiderMD5, "abc123")
    }

    func testFallbackSearchParsesMovieRowsAndPlayLinks() throws {
        let data = Data("{\"data\":{\"longData\":{\"rows\":[{\"en_id\":\"spider-1\",\"titleTxt\":\"蜘蛛侠1\",\"url\":\"https://example.com/movie\",\"playlinks\":{\"站点\":\"https://example.com/watch\"}}]}}}".utf8)
        let results = try TVBoxSearchParser.parse360(data: data)
        XCTAssertEqual(results.first?.name, "蜘蛛侠1")
        XCTAssertEqual(results.first?.playSources.first?.url?.absoluteString, "https://example.com/watch")
        XCTAssertEqual(results.first?.sourceName, "公开检索")
    }

    func testSourceStoreRoundTripsSnapshotAndReusesIDForSameLocation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVBoxMacOSTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(fileURL: directory.appendingPathComponent("library.json"))
        let location = URL(string: "https://example.com/live.m3u")!
        let source = TVSource(name: "Fixture", location: location, kind: .m3u)
        let channel = TVChannel(
            id: "news",
            name: "News",
            group: "Live",
            logoURL: nil,
            streamURL: URL(string: "https://example.com/news.m3u8")!,
            headers: [:]
        )
        let first = SourceSnapshot(
            source: source,
            channels: [channel],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            parserVersion: "test",
            warnings: []
        )

        let firstLibrary = try store.upsert(snapshot: first)
        XCTAssertEqual(firstLibrary.sources.count, 1)
        let originalID = try XCTUnwrap(firstLibrary.sources.first?.id)
        XCTAssertEqual(try store.load().sources.first?.snapshot?.channels, [channel])

        var updated = first
        updated.source = TVSource(name: "Renamed", location: location, kind: .m3u)
        let secondLibrary = try store.upsert(snapshot: updated)
        XCTAssertEqual(secondLibrary.sources.count, 1)
        XCTAssertEqual(secondLibrary.sources.first?.id, originalID)
        XCTAssertEqual(secondLibrary.sources.first?.source.name, "Renamed")
    }

    func testSourceStoreMissingFileReturnsEmptyAndRemoveClearsSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVBoxMacOSTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(fileURL: directory.appendingPathComponent("library.json"))
        XCTAssertEqual(try store.load(), SourceLibrary())

        let source = TVSource(
            name: "Fixture",
            location: URL(string: "https://example.com/live.m3u")!,
            kind: .m3u
        )
        let snapshot = SourceSnapshot(source: source, channels: [], fetchedAt: .now, parserVersion: "test", warnings: [])
        _ = try store.upsert(snapshot: snapshot)
        var library = try store.load()
        library.selectedSourceID = source.id
        try store.save(library)
        let removed = try store.remove(sourceID: source.id)
        XCTAssertTrue(removed.sources.isEmpty)
        XCTAssertNil(removed.selectedSourceID)
    }
}

extension SourceAdapterTests {
    func testSpiderDetailParserAcceptsNestedDataAndMissingName() throws {
        let site = TVBoxSite(key: "spider", name: "Spider", adapter: "csp_Demo",
                             spiderURL: URL(string: "https://example.com/spider.jar")!)
        let data = Data(#"{"data":{"list":[{"vod_id":"ID%2D1","vod_play_url":"正片$opaque"}]}}"#.utf8)
        let result = try TVBoxSearchParser.parse(data: data, site: site, fallbackName: "示例影片")
        XCTAssertEqual(result.first?.name, "示例影片")
        XCTAssertEqual(result.first?.vodID, "ID%2D1")
        XCTAssertEqual(result.first?.playSources.first?.playerID, "opaque")
        XCTAssertEqual(TVBoxSearchParser.normalizedIdentifier("ID-1"), TVBoxSearchParser.normalizedIdentifier("ID%2D1"))
    }

    func testSpiderDetailMatchKeepsUniqueResultWhenSiteChangesDisplayName() throws {
        let site = TVBoxSite(key: "spider", name: "Spider", adapter: "csp_Demo",
                             spiderURL: URL(string: "https://example.com/spider.jar")!)
        let search = try XCTUnwrap(TVBoxSearchParser.parse(
            data: Data(#"{"list":[{"vod_id":"movie-1","vod_name":"旧名称"}]}"#.utf8), site: site).first)
        let detail = try XCTUnwrap(TVBoxSearchParser.parse(
            data: Data(#"{"list":[{"vod_name":"新名称","vod_play_url":"正片$opaque"}]}"#.utf8), site: site).first)
        XCTAssertEqual(TVBoxSearchParser.matchDetail([detail], requestedID: search.vodID!, requestedName: search.name)?.name, "新名称")
    }

    func testSpiderPlaybackAcceptsNestedObjectURL() throws {
        let data = Data(#"{"data":{"parse":0,"jx":0,"url":{"url":" https://cdn.example/movie.m3u8 "}}}"#.utf8)
        let playback = try SourceLoader.parseSpiderPlayback(data: data)
        XCTAssertEqual(playback.url.absoluteString, "https://cdn.example/movie.m3u8")
    }

    func testSpiderPlaybackAcceptsCaseInsensitiveArrayWrapperAndQuotedURL() throws {
        let data = Data(#"{"RESULT":[{"Parse":false,"JX":false,"URL":"\"https://cdn.example/episode.m3u8\""}]}"#.utf8)
        let playback = try SourceLoader.parseSpiderPlayback(data: data)
        XCTAssertEqual(playback.url.absoluteString, "https://cdn.example/episode.m3u8")
    }

    func testSpiderCatalogPreservesObjectExtAndOpaquePlayerID() throws {
        let json = Data(#"{"spider":"https://example.com/spider.jpg;md5;abc","sites":[{"key":"huban","name":"虎斑","api":"csp_AiNewHuBanGuard","ext":{"token":"secret","enabled":true}}]}"#.utf8)
        let site = try XCTUnwrap(TVBoxJSONAdapter().parseCatalog(data: json).first)
        XCTAssertEqual(site.spiderExt, #"{"enabled":true,"token":"secret"}"#)
        let data = Data(#"{"list":[{"vod_id":"opaque-1","vod_name":"蜘蛛侠","vod_play_from":"虎斑","vod_play_url":"正片$opaque-play-id"}]}"#.utf8)
        let item = try XCTUnwrap(TVBoxSearchParser.parse(data: data, site: site).first)
        XCTAssertNil(item.playSources.first?.url)
        XCTAssertEqual(item.playSources.first?.playerID, "opaque-play-id")
        XCTAssertEqual(item.playSources.first?.flag, "虎斑")
        XCTAssertEqual(item.vodID, "opaque-1")
    }

    func testSpiderPlaybackRejectsParserAndAcceptsDirectHeaders() throws {
        let direct = Data(#"{"parse":0,"jx":0,"url":"https://cdn.example/movie.m3u8","header":{"Referer":"https://example.com"}}"#.utf8)
        let playback = try SourceLoader.parseSpiderPlayback(data: direct)
        XCTAssertEqual(playback.url.absoluteString, "https://cdn.example/movie.m3u8")
        XCTAssertEqual(playback.headers["Referer"], "https://example.com")
        let parsed = Data(#"{"parse":1,"jx":0,"url":"https://cdn.example/movie.m3u8"}"#.utf8)
        XCTAssertThrowsError(try SourceLoader.parseSpiderPlayback(data: parsed)) { error in
            XCTAssertTrue(error.localizedDescription.contains("嗅探"))
        }
        let auth = Data(#"{"list":[],"parse":0,"jx":0,"msg":"还没有配置 Cookie"}"#.utf8)
        XCTAssertThrowsError(try SourceLoader.parseSpiderPlayback(data: auth)) { error in
            XCTAssertTrue(error.localizedDescription.contains("站点无法提供播放地址"))
            XCTAssertTrue(error.localizedDescription.contains("Cookie"))
        }
    }
}
