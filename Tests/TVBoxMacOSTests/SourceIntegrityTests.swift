import XCTest
import Network
@testable import TVBoxMacOS

final class SourceIntegrityTests: XCTestCase {
    /// 同包同 key 的影片按订阅区分；同一订阅内凭据轮换、名称更新保持 ID。
    func testCatalogNamespacesStayStableAcrossMetadataChanges() async throws {
        let (directory, url) = try temporaryCatalog(ext: "old-token")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TVSource(name: "源一", location: url, kind: .tvboxJSON)
        let second = TVSource(name: "源二", location: url, kind: .tvboxJSON)
        let loader = SourceLoader()
        let originalCatalog = try await loader.loadCatalog(source: first)
        let original = try XCTUnwrap(originalCatalog.first)
        let otherCatalog = try await loader.loadCatalog(source: second)
        let differentSource = try XCTUnwrap(otherCatalog.first)
        XCTAssertNotEqual(try movie(original).id, try movie(differentSource).id)
        try catalog(ext: "new-token", name: "新站名").write(to: url)
        SourceLoader.invalidateCatalog(url: url)
        let refreshedCatalog = try await loader.loadCatalog(source: first)
        let refreshed = try XCTUnwrap(refreshedCatalog.first)
        XCTAssertEqual(try movie(original).id, try movie(refreshed).id)
        XCTAssertEqual(refreshed.spiderExt, "new-token")
    }

    /// 非规范订阅中重复 key 的不同 ext 不可再被去重丢弃。
    func testDuplicateSiteKeysRetainDistinctConfigurations() async throws {
        let (directory, url) = try temporaryCatalog(ext: "one")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"spider":"https://fixture.example/pkg.jar","sites":[{"key":"same","name":"一","api":"csp_Test","ext":"one"},{"key":"same","name":"二","api":"csp_Test","ext":"two"}]}"#.utf8).write(to: url)
        let source = TVSource(name: "源", location: url, kind: .tvboxJSON)
        let sites = try await SourceLoader().loadCatalog(source: source)
        XCTAssertEqual(sites.count, 2)
        XCTAssertNotEqual(try movie(sites[0]).id, try movie(sites[1]).id)
    }

    /// 无订阅上下文的解析也不可把不同 ext 误认成同一影片。
    func testStandaloneIdentityAndConservativeFavoriteMigration() throws {
        let firstSite = try XCTUnwrap(TVBoxJSONAdapter().parseCatalog(data: catalog(ext: "one")).first)
        let secondSite = try XCTUnwrap(TVBoxJSONAdapter().parseCatalog(data: catalog(ext: "two")).first)
        XCTAssertNotEqual(try movie(firstSite).id, try movie(secondSite).id)
        let old = TVMediaItem(id: firstSite.legacyMediaID(vodID: "42"), name: "影片", sourceName: "订阅", siteKey: "same", spiderSite: firstSite, vodID: "42")
        var scoped = firstSite
        scoped.sourceNamespace = "source-one"
        var current = try movie(scoped)
        current.sourceName = "订阅"
        XCTAssertTrue(current.matchesFavorite(old))
        var otherSite = secondSite
        otherSite.sourceNamespace = "source-two"
        var other = try movie(otherSite)
        other.sourceName = "订阅"
        XCTAssertFalse(other.matchesFavorite(old))
        XCTAssertFalse(current.matchesFavorite(other))
        let decoded = try JSONDecoder().decode(TVMediaItem.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded, current)
    }

    /// 同样的 JSON 无论从磁盘还是 HTTP 导入都展开 lives.url 并保留请求头。
    func testLocalAndRemoteImportsExpandIdenticalPlaylists() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let loader = SourceLoader(session: session)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("source.json")
        try IntegrityFixtureProtocol.sourceJSON.write(to: local)
        let localSnapshot = try await loader.load(fileURL: local)
        let remoteSnapshot = try await loader.load(url: URL(string: "https://integrity-fixture.example/source.json")!)
        XCTAssertEqual(localSnapshot.channels.count, 1)
        XCTAssertEqual(localSnapshot.channels.map(\.name), remoteSnapshot.channels.map(\.name))
        XCTAssertEqual(localSnapshot.channels.first?.streamURL, remoteSnapshot.channels.first?.streamURL)
        XCTAssertEqual(localSnapshot.channels.first?.headers["User-Agent"], "FixtureAgent")
        XCTAssertEqual(localSnapshot.channels.first?.name, "展开频道")
        XCTAssertTrue(localSnapshot.warnings.isEmpty)
    }

    /// Content-Length 缺失时仍按实际字节取消超限响应，不等待服务器结束。
    func testBoundedReaderRejectsChunkedOverflow() async throws {
        let server = try StreamingFixtureServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\nC\r\n123456789012\r\n")
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await BoundedResponseReader.read(URLRequest(url: url), session: .shared, maximumBytes: 8, timeout: 2)
            XCTFail("超限响应不应成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("大小限制"), error.localizedDescription)
        }
    }

    /// 大 Content-Length 可在响应头阶段拒绝，避免继续下载错误的媒体地址。
    func testBoundedReaderRejectsDeclaredOversize() async throws {
        let server = try StreamingFixtureServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\n\r\n{")
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await BoundedResponseReader.read(URLRequest(url: url), session: .shared, maximumBytes: 8, timeout: 2)
            XCTFail("声明超限响应不应成功")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("大小限制"), error.localizedDescription)
        }
    }

    /// 总耗时计时从发起请求开始，尚未返回响应头或正文停滞均可被终止。
    func testBoundedReaderDeadlineCoversHeadersAndStalledBody() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        for path in ["no-headers", "stalled"] {
            let start = Date()
            do {
                _ = try await BoundedResponseReader.read(URLRequest(url: URL(string: "https://integrity-fixture.example/\(path)")!), session: session, timeout: 0.1)
                XCTFail("停滞响应不应成功")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
                XCTAssertLessThan(Date().timeIntervalSince(start), 2)
            }
        }
    }

    /// 调用方取消必须取消自己的请求并及时完成，不能影响其他请求的 session。
    func testBoundedReaderCancellation() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let operation = Task {
            try await BoundedResponseReader.read(URLRequest(url: URL(string: "https://integrity-fixture.example/no-headers")!), session: session)
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("取消请求不应成功") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = try await SourceLoader(session: session).load(url: URL(string: "https://integrity-fixture.example/source.json")!)
        XCTAssertEqual(snapshot.channels.count, 1)
    }

    /// 流式回调即使一次交付大量字节，前缀探测也在检查点取消，不能读完媒体。
    func testBoundedReaderStopsAtPrefixBeforeChunkOverflow() async throws {
        let payload = String(repeating: "x", count: 16_384)
        let server = try StreamingFixtureServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n4000\r\n\(payload)\r\n")
        let url = try await server.start()
        defer { server.stop() }
        let (data, _) = try await BoundedResponseReader.read(URLRequest(url: url), session: .shared,
                                                           maximumBytes: 1024, timeout: 2, prefixCheckpoints: [512]) { data, _ in data.count == 512 }
        XCTAssertEqual(data.count, 512)
    }

    /// 已发出部分正文后即使不再收到字节，探测仍受独立总计时约束。
    func testPrefixProbeDeadlineCancelsStalledTCPBody() async throws {
        let server = try StreamingFixtureServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n#\r\n")
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await BoundedResponseReader.read(URLRequest(url: url), session: .shared,
                                                    timeout: 0.1, prefixCheckpoints: [512, 4096]) { _, _ in false }
            XCTFail("停滞探测不应成功")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }

    /// 取消发生在直播列表展开期间，不能返回还能被保存的部分展开快照。
    func testCancellingLocalImportDuringExpansionThrows() async throws {
        let started = expectation(description: "列表请求已开始")
        let server = try StreamingFixtureServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n#\r\n", onRequest: { started.fulfill() })
        let url = try await server.start()
        defer { server.stop() }
        let (directory, fileURL) = try temporaryCatalog(ext: "ignored")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"lives\":[{\"name\":\"列表\",\"url\":\"\(url.absoluteString)\"}]}".utf8).write(to: fileURL)
        let operation = Task { try await SourceLoader().load(fileURL: fileURL) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("取消导入不应返回快照") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    /// 本地和远程导入都在开始读取前拒绝已取消任务。
    func testCancelledImportEntrypointsDoNotReadOrReturnSnapshots() async throws {
        let (directory, fileURL) = try temporaryCatalog(ext: "ignored")
        defer { try? FileManager.default.removeItem(at: directory) }
        for local in [true, false] {
            let operation = Task {
                if local { return try await SourceLoader().load(fileURL: fileURL) }
                return try await SourceLoader().load(url: URL(string: "https://integrity-fixture.example/unused")!)
            }
            operation.cancel()
            do { _ = try await operation.value; XCTFail("取消导入不应返回快照") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    /// 失效时仍在下载的旧请求即使晚于新请求完成，也不得重新污染目录缓存。
    func testInvalidationPreventsStaleInflightCatalogWriteback() async throws {
        let firstStarted = expectation(description: "旧请求已开始")
        CatalogRaceProtocol.reset { firstStarted.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogRaceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let loader = SourceLoader(session: session)
        let url = URL(string: "https://catalog-race.example/\(UUID().uuidString).json")!
        let oldRequest = Task { try await loader.loadCatalog(url: url) }
        await fulfillment(of: [firstStarted], timeout: 2)
        SourceLoader.invalidateCatalog(url: url)
        let fresh = try await loader.loadCatalog(url: url)
        XCTAssertEqual(fresh.first?.name, "new")
        let old = try await oldRequest.value
        XCTAssertEqual(old.first?.name, "old")
        let cached = try await loader.loadCatalog(url: url)
        XCTAssertEqual(cached.first?.name, "new")
    }

    /// 生成隔离目录中的小型站源配置。
    private func temporaryCatalog(ext: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("catalog.json")
        try catalog(ext: ext).write(to: url)
        return (directory, url)
    }

    /// 固定同一包和 key，变化字段仅为站点配置及展示名称。
    private func catalog(ext: String, name: String = "站点") -> Data {
        Data("{\"spider\":\"https://fixture.example/pkg.jar\",\"sites\":[{\"key\":\"same\",\"name\":\"\(name)\",\"api\":\"csp_Test\",\"ext\":\"\(ext)\"}]}".utf8)
    }

    /// 真实搜索解析入口构造相同 vod_id 的结果。
    private func movie(_ site: TVBoxSite) throws -> TVMediaItem {
        try XCTUnwrap(TVBoxSearchParser.parse(data: Data(#"{"list":[{"vod_id":"42","vod_name":"影片"}]}"#.utf8), site: site).first)
    }

    /// 网络测试只访问 URLProtocol，避免依赖真实外网和用户凭据。
    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrityFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// 同时模拟正常频道列表、无长度响应、声明超限和永不结束的连接。
private final class IntegrityFixtureProtocol: URLProtocol {
    static let sourceJSON = Data(#"{"lives":[{"name":"频道组","url":"https://integrity-fixture.example/channels.m3u","ua":"FixtureAgent"}]}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "integrity-fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 超限测试不发送完成事件，证明生产读取器自行终止。
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/no-headers" { return }
        let headers = url.path == "/declared" ? ["Content-Length": "1000000"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/stalled" || url.path == "/declared" { return }
        if url.path == "/overflow" {
            for _ in 0..<3 { client?.urlProtocol(self, didLoad: Data("1234".utf8)) }
            return
        }
        let data = url.pathExtension == "json" ? Self.sourceJSON : Data("#EXTM3U\n#EXTINF:-1,展开频道\nhttps://cdn.example/channel.m3u8\n".utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// URLProtocol 对未结束响应可能缓冲回调；真实 loopback TCP 连接验证下载中途拒绝。
private final class StreamingFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "source-integrity-http-fixture")
    private let response: Data
    private let onRequest: (() -> Void)?
    private var connections: [NWConnection] = []
    private var ready = false

    /// 明确绑定本机回环随机端口，不向局域网暴露测试服务。
    init(response: String, onRequest: (() -> Void)? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.response = Data(response.utf8)
        self.onRequest = onRequest
    }

    /// 收到 HTTP 请求后仅发送指定前缀并保持连接，迫使客户端主动结束请求。
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard !ready else { return }
                switch state {
                case .ready:
                    ready = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/fixture")!)
                case .failed(let error): ready = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [response, onRequest] _, _, _, _ in
                    onRequest?()
                    connection.send(content: response, completion: .contentProcessed { _ in })
                }
            }
            listener.start(queue: queue)
        }
    }

    /// 在同一串行队列释放所有连接，避免测试结束后留下监听器或悬挂任务。
    func stop() {
        queue.sync {
            listener.cancel()
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

/// 按完成顺序倒置的两个响应，验证重导入失效和后台旧目录请求之间的竞态。
private final class CatalogRaceProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestCount = 0
    private static var onFirstRequest: (() -> Void)?

    /// 每次测试隔离计数和启动事件；共享状态只在锁内访问。
    static func reset(onFirstRequest: @escaping () -> Void) {
        lock.lock()
        requestCount = 0
        self.onFirstRequest = onFirstRequest
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "catalog-race.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 旧响应延迟完成，使新的配置读取先进入缓存。
    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let first = Self.requestCount == 1
        let callback = Self.onFirstRequest
        Self.lock.unlock()
        if first { callback?() }
        let deliver = { [self] in
            guard let url = request.url else { return }
            let name = first ? "old" : "new"
            let data = Data("{\"sites\":[{\"key\":\"same\",\"name\":\"\(name)\",\"api\":\"https://cms.example/api.php\"}]}".utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if first { DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: deliver) }
        else { deliver() }
    }

    override func stopLoading() {}
}
