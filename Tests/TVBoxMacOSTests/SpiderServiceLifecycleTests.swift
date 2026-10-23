import XCTest
@testable import TVBoxMacOS

@MainActor
final class SpiderServiceLifecycleTests: XCTestCase {
    /// 两个窗口同时启动只发送一次初始探测；取消一个等待者不会停止共享启动任务。
    func testConcurrentStartSurvivesCancelledWaiter() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        SpiderHealthFixtureProtocol.reset()
        let service = SpiderService(session: session, monitorInterval: 60_000_000_000)
        defer { service.stop() }
        let first = Task { await service.start() }
        let second = Task { await service.start() }
        try await Task.sleep(nanoseconds: 20_000_000)
        first.cancel()
        await first.value
        XCTAssertEqual(service.state, .starting, "Cancelled waiter must return before the shared startup completes")
        await second.value
        XCTAssertTrue(service.isReady)
        XCTAssertEqual(SpiderHealthFixtureProtocol.requestCount, 1)
        XCTAssertEqual(SpiderHealthFixtureProtocol.lastToken, service.token)
    }

    /// 复用已有健康服务也要监控断线，并能在服务恢复后重新标记就绪。
    func testReusedServiceContinuesMonitoring() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        SpiderHealthFixtureProtocol.reset()
        let service = SpiderService(session: session, monitorInterval: 10_000_000)
        defer { service.stop() }
        await service.start()
        XCTAssertTrue(service.isReady)
        SpiderHealthFixtureProtocol.healthy = false
        try await waitForState(.recovering, service: service)
        SpiderHealthFixtureProtocol.healthy = true
        try await waitForState(.ready, service: service)
    }

    /// stop 发生在初次 health await 期间时，过期响应不能重新启动或置为 ready。
    func testStopInvalidatesPendingInitialHealth() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        SpiderHealthFixtureProtocol.reset()
        let service = SpiderService(session: session)
        let startup = Task { await service.start() }
        try await Task.sleep(nanoseconds: 20_000_000)
        service.stop()
        await startup.value
        XCTAssertEqual(service.state, .stopped)
    }

    /// 收藏的直接播放路径自己保证服务就绪，不依赖此前打开详情或搜索。
    func testColdPlaybackEnsuresServiceBeforeResolving() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        SpiderHealthFixtureProtocol.reset()
        let spider = SpiderService(session: session, monitorInterval: 60_000_000_000)
        defer { spider.stop() }
        let site = TVBoxSite(key: "test", name: "站点", adapter: "csp_Test",
                             spiderURL: URL(string: "https://example.com/spider.jar"))
        let item = TVMediaItem(id: "one", name: "影片", spiderSite: site)
        do {
            _ = try await MovieApplicationService(spider: spider, loader: SourceLoader(session: session))
                .resolve(item: item, source: TVPlaySource(name: "缺少 ID"))
            XCTFail("缺少播放 ID 应返回业务错误")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("播放 ID"))
        }
        XCTAssertTrue(spider.isReady)
        XCTAssertEqual(SpiderHealthFixtureProtocol.requestCount, 1)
    }

    /// 已取消的业务请求不应发起服务启动或网络探测。
    func testCancelledEnsureReadyDoesNotStartService() async {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        SpiderHealthFixtureProtocol.reset()
        let spider = SpiderService(session: session)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            do { try await spider.ensureReady(); XCTFail("取消应向上传播") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        task.cancel()
        await task.value
        XCTAssertEqual(spider.state, .stopped)
        XCTAssertEqual(SpiderHealthFixtureProtocol.requestCount, 0)
    }

    /// 用有界轮询等待状态变化，避免按固定延迟假定任务已完成。
    private func waitForState(_ state: SpiderService.State, service: SpiderService) async throws {
        let deadline = Date().addingTimeInterval(2)
        while service.state != state, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(service.state, state)
    }

    /// 注入认证健康响应，不启动真实模拟器或修改本地运行时。
    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpiderHealthFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class SpiderHealthFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var token: String?
    private static var ready = true
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static var lastToken: String? { lock.lock(); defer { lock.unlock() }; return token }
    static var healthy: Bool {
        get { lock.lock(); defer { lock.unlock() }; return ready }
        set { lock.lock(); defer { lock.unlock() }; ready = newValue }
    }
    private var work: DispatchWorkItem?

    /// 清除各测试之间的统计与健康状态。
    static func reset() { lock.lock(); defer { lock.unlock() }; count = 0; token = nil; ready = true }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.token = request.value(forHTTPHeaderField: "X-TVBox-Token")
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let body = Data("{\"ready\":\(Self.healthy)}".utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}
