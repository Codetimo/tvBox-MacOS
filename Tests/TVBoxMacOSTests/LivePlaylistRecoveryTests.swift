import XCTest
@testable import TVBoxMacOS

final class LivePlaylistRecoveryTests: XCTestCase {
    func testUnwrapsOnlyExplicitGitHubOriginAndPreservesEncoding() {
        let url = URL(string: "https://ghp.ci/raw.githubusercontent.com/owner/repo/main/a%20b.m3u?x=A%2Fb")!
        XCTAssertEqual(LivePlaylistRecovery.originalGitHubURL(url)?.absoluteString,
                       "https://raw.githubusercontent.com/owner/repo/main/a%20b.m3u?x=A%2Fb")
        for raw in ["https://other.example/raw.githubusercontent.com/a", "https://ghp.ci/evil.example/a",
                    "https://ghp.ci/raw.githubusercontent.com.evil.example/a", "http://ghp.ci/raw.githubusercontent.com/a"] {
            XCTAssertNil(LivePlaylistRecovery.originalGitHubURL(URL(string: raw)!))
        }
    }

    func testNestedM3UResolvesRelativeURLsAndVLCHeaders() throws {
        let data = Data("#EXTM3U\n#EXTINF:-1 group-title=\"测试\",新闻\n#EXTVLCOPT:http-user-agent=ChannelAgent\n#EXTVLCOPT:http-referrer=https://origin.example/\n../live/news.m3u8?token=A%2Fb\n".utf8)
        let snapshot = try M3UAdapter().parse(data: data, source: source(), playlistURL: URL(string: "https://cdn.example/lists/channels.m3u")!)
        XCTAssertEqual(snapshot.channels.first?.streamURL.absoluteString, "https://cdn.example/live/news.m3u8?token=A%2Fb")
        XCTAssertEqual(snapshot.channels.first?.headers["User-Agent"], "ChannelAgent")
        XCTAssertEqual(snapshot.channels.first?.headers["Referer"], "https://origin.example/")
    }

    func testNestedHLSUsesPlaylistURLRatherThanTopLevelJSON() throws {
        let url = URL(string: "https://cdn.example/live/index.m3u8")!
        let data = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n".utf8)
        let snapshot = try M3UAdapter().parse(data: data, source: source(), playlistURL: url)
        XCTAssertEqual(snapshot.channels.first?.streamURL, url)
    }

    func testTextPlaylistKeepsGroupsAndRejectsHTML() throws {
        let data = Data("央视频道,#genre#\nCCTV1,https://cdn.example/live.m3u8\n地方频道,#genre#\n新闻,https://cdn.example/news.m3u8\n".utf8)
        let channels = try LivePlaylistRecovery.parseText(data, source: source(), headers: ["User-Agent": "TV"])
        XCTAssertEqual(channels.map(\.group), ["央视频道", "地方频道"])
        XCTAssertEqual(channels.first?.headers["User-Agent"], "TV")
        XCTAssertFalse(LivePlaylistRecovery.isTextPlaylist(Data("<html>bad,https://error.example</html>".utf8)))
    }

    func testRepairExpandsMirroredListsWithoutFetchingExistingChannels() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let original = channel("real", group: "央视频道", url: "https://must-not-fetch.example/live.m3u8")
        let mirror = channel("mirror", url: "https://ghp.ci/raw.githubusercontent.com/owner/repo/main/good.m3u")
        let snapshot = SourceSnapshot(source: source(), channels: [original, mirror], fetchedAt: .now, parserVersion: "old", warnings: [])
        let repaired = await SourceLoader(session: session).repairStoredLivePlaylists(in: snapshot)
        let result = try XCTUnwrap(repaired)
        XCTAssertEqual(result.channels.count, 2)
        XCTAssertEqual(result.channels.first, original)
        XCTAssertEqual(result.channels.last?.name, "可用新闻")
        XCTAssertEqual(result.channels.last?.headers["User-Agent"], "InheritedAgent")
        XCTAssertEqual(result.parserVersion, "tvbox-json-3")
        XCTAssertTrue(result.warnings.contains { $0.contains("GitHub") })
    }

    func testFailedListAndAndroidProxyAreNotPlayableChannels() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let snapshot = SourceSnapshot(source: source(), channels: [
            channel("missing", url: "https://ghp.ci/raw.githubusercontent.com/owner/repo/main/missing.m3u"),
            channel("proxy", url: "http://127.0.0.1:9978/proxy?do=live")
        ], fetchedAt: .now, parserVersion: "old", warnings: [])
        let repaired = await SourceLoader(session: session).repairStoredLivePlaylists(in: snapshot)
        let result = try XCTUnwrap(repaired)
        XCTAssertTrue(result.channels.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("HTTP 404") })
        XCTAssertTrue(result.warnings.contains { $0.contains("Android TVBox") })
    }

    func testRecoveredHLSKeepsOriginURLInsteadOfFailedMirror() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let snapshot = SourceSnapshot(source: source(), channels: [
            channel("hls", url: "https://ghp.ci/raw.githubusercontent.com/owner/repo/main/media.m3u8")
        ], fetchedAt: .now, parserVersion: "old", warnings: [])
        let repaired = await SourceLoader(session: session).repairStoredLivePlaylists(in: snapshot)
        XCTAssertEqual(repaired?.channels.first?.streamURL.host, "raw.githubusercontent.com")
        XCTAssertEqual(repaired?.channels.first?.id, "hls")
    }

    func testRecoveredHTMLResponseDoesNotBecomePlayableChannel() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let snapshot = SourceSnapshot(source: source(), channels: [
            channel("html", url: "https://ghp.ci/raw.githubusercontent.com/owner/repo/main/error.m3u")
        ], fetchedAt: .now, parserVersion: "old", warnings: [])
        let repaired = await SourceLoader(session: session).repairStoredLivePlaylists(in: snapshot)
        XCTAssertTrue(try XCTUnwrap(repaired).channels.isEmpty)
        XCTAssertTrue(repaired?.warnings.contains { $0.contains("未返回可识别") } == true)
    }

    func testRepairDoesNothingForAlreadyExpandedSnapshot() async {
        let snapshot = SourceSnapshot(source: source(), channels: [channel("real", group: "Live", url: "https://cdn.example/live.m3u8")], fetchedAt: .now, parserVersion: "old", warnings: [])
        let result = await SourceLoader().repairStoredLivePlaylists(in: snapshot)
        XCTAssertNil(result)
    }

    private func source() -> TVSource {
        TVSource(name: "测试源", location: URL(string: "https://source.example/config.json")!, kind: .tvboxJSON)
    }

    private func channel(_ name: String, group: String = "Live", url: String) -> TVChannel {
        TVChannel(id: name, name: name, group: group, logoURL: nil, streamURL: URL(string: url)!, headers: ["User-Agent": "InheritedAgent"])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveRecoveryFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class LiveRecoveryFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        // 若代码仍请求失效镜像或重新探测已展开频道，测试即失败。
        guard url.host == "raw.githubusercontent.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        let missing = url.lastPathComponent == "missing.m3u"
        let body: String
        if url.lastPathComponent == "media.m3u8" {
            body = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#" + String(repeating: "a", count: 600) + "\n#EXTINF:6,\nsegment.ts\n"
        } else if url.lastPathComponent == "error.m3u" {
            body = "<html>" + String(repeating: "error", count: 150) + "</html>"
        } else {
            body = missing ? "404 Not Found" : "#EXTM3U\n#EXTINF:-1 group-title=\"央视频道\",可用新闻\nhttps://cdn.example/news.m3u8\n"
        }
        let data = Data(body.utf8)
        let response = HTTPURLResponse(url: url, statusCode: missing ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
