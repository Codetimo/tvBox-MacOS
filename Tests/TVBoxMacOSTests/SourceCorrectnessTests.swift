import XCTest
@testable import TVBoxMacOS

final class SourceCorrectnessTests: XCTestCase {
    /// 从 TVBox 导入入口验证 HLS 仍保留频道名、播放地址及站点要求的请求头。
    func testTVBoxImportDoesNotExpandHLSIntoSegments() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LivePlaylistFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let snapshot = try await SourceLoader(session: session).load(url: URL(string: "https://live-fixture.example/source.json")!)
        XCTAssertEqual(snapshot.channels.count, 1)
        XCTAssertEqual(snapshot.channels.first?.name, "新闻直播")
        XCTAssertEqual(snapshot.channels.first?.streamURL.absoluteString, "https://live-fixture.example/live.m3u8?token=AbC")
        XCTAssertEqual(snapshot.channels.first?.headers["User-Agent"], "FixtureAgent")
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    /// 512 字节预读边界截到汉字中间时仍应识别有效 UTF-8 文件头。
    func testPlaylistPrefixAcceptsSplitUTF8Character() async throws {
        let snapshot = try await loadPlaylistFixture("utf8-boundary")
        XCTAssertEqual(snapshot.channels.first?.name, "展开频道")
        XCTAssertEqual(snapshot.channels.first?.streamURL.absoluteString, "https://cdn.example/channel.m3u8")
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    /// 有限预读与正式解析应一致支持带 BOM 的 UTF-16 频道列表。
    func testPlaylistPrefixAcceptsUTF16() async throws {
        let snapshot = try await loadPlaylistFixture("utf16")
        XCTAssertEqual(snapshot.channels.first?.name, "展开频道")
        XCTAssertEqual(snapshot.channels.first?.streamURL.absoluteString, "https://cdn.example/channel.m3u8")
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    /// 创建隔离网络会话，通过真实导入入口读取指定编码的频道列表。
    private func loadPlaylistFixture(_ name: String) async throws -> SourceSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LivePlaylistFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await SourceLoader(session: session).load(url: URL(string: "https://live-fixture.example/\(name).json")!)
    }

    /// HLS 分片必须交给播放器，不能作为可收藏的独立频道导入。
    func testHLSMediaPlaylistRemainsOneChannel() throws {
        let data = Data("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nhttps://cdn.example/one.ts\n#EXTINF:10,\nhttps://cdn.example/two.ts\n#EXT-X-ENDLIST\n".utf8)
        let source = TVSource(name: "直播", location: URL(string: "https://cdn.example/live.m3u8")!, kind: .m3u)
        XCTAssertTrue(M3UAdapter.isHLSPlaylist(data: data))
        XCTAssertFalse(M3UAdapter.isChannelPlaylist(data: data))
        let snapshot = try M3UAdapter().parse(data: data, source: source)
        XCTAssertEqual(snapshot.channels.count, 1)
        XCTAssertEqual(snapshot.channels.first?.streamURL, source.location)
        XCTAssertEqual(snapshot.channels.first?.name, "直播")
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    /// 多码率 HLS 与 UTF-16/BOM 的频道列表需走不同导入路径。
    func testMasterPlaylistAndChannelListAreDistinguished() throws {
        let master = Data("\u{feff}#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\n720p.m3u8\n".utf8)
        XCTAssertTrue(M3UAdapter.isHLSPlaylist(data: master))
        XCTAssertFalse(M3UAdapter.isChannelPlaylist(data: master))
        let channels = "#EXTM3U\n#EXTINF:-1,新闻\nhttps://cdn.example/live.m3u8\n".data(using: .utf16)!
        XCTAssertFalse(M3UAdapter.isHLSPlaylist(data: channels))
        XCTAssertTrue(M3UAdapter.isChannelPlaylist(data: channels))
        XCTAssertFalse(M3UAdapter.isChannelPlaylist(data: Data("<html>error</html>".utf8)))
    }

    /// 路径与签名值的大小写会改变实际资源，只折叠协议和域名的大小写。
    func testURLDeduplicationPreservesCaseSensitivePathsAndSignatures() {
        let urls = ["https://EXAMPLE.com/Video?token=AbC", "https://example.com/Video?token=AbC",
                    "https://example.com/video?token=AbC", "https://example.com/Video?token=abc"]
        let channels = urls.enumerated().map { channel("id-\($0.offset)", name: "频道", url: $0.element) }
        XCTAssertEqual(deduplicatedChannels(channels).map(\.id), ["id-0", "id-2", "id-3"])
        let signed = URL(string: "https://EXAMPLE.com/Video%2F1?token=A%2fb%2Bc&x=1&x=2")!
        XCTAssertEqual(channelURLIdentity(signed), "https://example.com/Video%2F1?token=A%2fb%2Bc&x=1&x=2")
    }

    /// 错误 ID 即使名称相同也不可作为请求影片播放。
    func testDetailRejectsExplicitConflictingID() {
        let wrong = TVMediaItem(id: "wrong", name: "影片", vodID: "wrong-id")
        XCTAssertNil(TVBoxSearchParser.matchDetail([wrong], requestedID: "expected-id", requestedName: "影片"))
        XCTAssertNil(TVBoxSearchParser.matchDetail([wrong], requestedID: "expected-id", requestedName: "另一影片"))
    }

    /// 兼容省略 ID 或改变展示名的提供商，同时优先选择真实匹配的 ID。
    func testDetailAcceptsMissingIDAndPrioritizesExactID() {
        let missing = TVMediaItem(id: "missing", name: "新展示名")
        let exact = TVMediaItem(id: "exact", name: "不同展示名", vodID: "movie%2D1")
        XCTAssertEqual(TVBoxSearchParser.matchDetail([missing], requestedID: "movie-1", requestedName: "旧展示名")?.id, "missing")
        XCTAssertEqual(TVBoxSearchParser.matchDetail([missing, exact], requestedID: "movie-1", requestedName: "新展示名")?.id, "exact")
        let emptyID = TVMediaItem(id: "empty", name: "新展示名", vodID: "  ")
        XCTAssertEqual(TVBoxSearchParser.matchDetail([emptyID], requestedID: "movie-1", requestedName: "旧展示名")?.id, "empty")
    }

    /// 重导入真实解析结果后，旧收藏 ID 与新快照仍相交，且新频道归属已有源。
    func testReimportPreservesFavoriteIdentityAndRebasesNewChannels() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = URL(string: "https://example.com/channels.m3u")!
        let firstSource = TVSource(name: "源", location: location, kind: .m3u)
        let data = Data("#EXTM3U\n#EXTINF:-1,新闻\nhttps://example.com/live\n".utf8)
        let first = try M3UAdapter().parse(data: data, source: firstSource)
        _ = try store.upsert(snapshot: first)
        let favorites = Set(first.channels.map(\.id))
        let secondSource = TVSource(name: "更新源", location: location, kind: .m3u)
        let updated = try M3UAdapter().parse(data: data + Data("#EXTINF:-1,体育\nhttps://example.com/sports\n".utf8), source: secondSource)
        let result = try XCTUnwrap(store.upsert(snapshot: updated).sources.first?.snapshot)
        XCTAssertEqual(result.source.id, firstSource.id)
        XCTAssertEqual(result.channels.filter { favorites.contains($0.id) }.count, 1)
        XCTAssertTrue(result.channels[1].id.hasPrefix(firstSource.id.uuidString))
        XCTAssertEqual(try store.load().sources.first?.snapshot?.channels, result.channels)
    }

    /// 历史快照可能包含错误的源 UUID 或其他旧 ID 格式，更新不得破坏已存收藏。
    func testLegacyIDSurvivesSignedURLRotation() throws {
        let old = channel("legacy-favorite-id", name: "新闻", url: "https://example.com/live?token=old")
        let current = channel("new-import-id", name: "新闻", url: "https://example.com/live?token=new")
        let result = try updatedChannels(previous: [old], current: [current])
        XCTAssertEqual(result.first?.id, old.id)
        XCTAssertEqual(result.first?.streamURL, current.streamURL)
    }

    /// 同名频道不能靠名称猜测身份；精确地址匹配优先于另一个频道的名称匹配。
    func testAmbiguousNamesDoNotReuseOldFavorites() throws {
        let old = channel("old-favorite", name: "新闻", url: "https://example.com/old")
        let current = [channel("new-a", name: "新闻", url: "https://example.com/a"),
                       channel("new-b", name: "新闻", url: "https://example.com/b")]
        XCTAssertFalse(try updatedChannels(previous: [old], current: current).contains { $0.id == old.id })
        let competing = [channel("new-a", name: "新闻", url: "https://example.com/new"),
                         channel("new-b", name: "新名称", url: "https://example.com/old")]
        let result = try updatedChannels(previous: [old], current: competing)
        XCTAssertNotEqual(result[0].id, old.id)
        XCTAssertEqual(result[1].id, old.id)
    }

    /// 创建隔离的持久化路径，避免读取或修改用户源库。
    private func makeStore() -> (SourceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (SourceStore(fileURL: directory.appendingPathComponent("library.json")), directory)
    }

    /// 使用生产持久化流程验证两次导入的频道身份。
    private func updatedChannels(previous: [TVChannel], current: [TVChannel]) throws -> [TVChannel] {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TVSource(name: "源", location: URL(string: "https://example.com/list.m3u")!, kind: .m3u)
        _ = try store.upsert(snapshot: SourceSnapshot(source: source, channels: previous, fetchedAt: .now, parserVersion: "test", warnings: []))
        let imported = TVSource(name: "源", location: source.location, kind: .m3u)
        return try XCTUnwrap(store.upsert(snapshot: SourceSnapshot(source: imported, channels: current, fetchedAt: .now, parserVersion: "test", warnings: [])).sources.first?.snapshot).channels
    }

    /// 构造带显式历史 ID 的频道，用于验证收藏引用兼容。
    private func channel(_ id: String, name: String, url: String) -> TVChannel {
        TVChannel(id: id, name: name, group: "直播", logoURL: nil, streamURL: URL(string: url)!, headers: [:])
    }
}

/// 返回固定的 TVBox 配置和 HLS 清单，验证真实加载流程且不访问外部站点。
private final class LivePlaylistFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "live-fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// HLS 同时提供绝对分片地址，确保旧实现会错误展开并被此测试捕获。
    override func startLoading() {
        guard let url = request.url else { return }
        let isSource = url.pathExtension == "json"
        let encodingFixture = url.path.contains("utf8-boundary") || url.path.contains("utf16")
        let data: Data
        if encodingFixture && isSource {
            let nested = url.deletingPathExtension().appendingPathExtension("m3u").absoluteString
            data = Data("{\"lives\":[{\"name\":\"频道组\",\"url\":\"\(nested)\"}]}".utf8)
        } else if encodingFixture {
            // 9 字节头 + 502 字节注释使第 512 字节落在“中”的 UTF-8 编码内部。
            let body = "#EXTM3U\n#" + String(repeating: "a", count: 502) + "中\n#EXTINF:-1,展开频道\nhttps://cdn.example/channel.m3u8\n"
            data = url.path.contains("utf16") ? body.data(using: .utf16)! : Data(body.utf8)
        } else {
            let body = isSource
                ? #"{"lives":[{"name":"新闻直播","url":"https://live-fixture.example/live.m3u8?token=AbC","ua":"FixtureAgent"}]}"#
                : "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nhttps://live-fixture.example/one.ts\n#EXTINF:10,\nhttps://live-fixture.example/two.ts\n#EXT-X-ENDLIST\n"
            data = Data(body.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": isSource ? "application/json" : "application/vnd.apple.mpegurl"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
