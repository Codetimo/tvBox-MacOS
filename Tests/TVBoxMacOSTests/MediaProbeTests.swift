import XCTest
@testable import TVBoxMacOS

final class MediaProbeTests: XCTestCase {
    /// 自定义 HTTP 头即使用小写也覆盖默认值，探测与播放器保持一致身份。
    func testHeaderOverridesAreCaseInsensitive() {
        let headers = playbackHTTPHeaders(overrides: ["user-agent": "FixtureAgent", "accept": "video/*"])
        XCTAssertEqual(headers["user-agent"], "FixtureAgent")
        XCTAssertEqual(headers["accept"], "video/*")
        XCTAssertNil(headers["User-Agent"])
        XCTAssertNil(headers["Accept"])
    }

    /// 字节特征优先，防止错误 MIME 或扩展名把网页当视频或漏掉真实媒体。
    func testRecognizesMediaAndHTMLFromContent() {
        XCTAssertEqual(MediaProbe.classify(prefix: Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n".utf8), contentType: "text/plain"), .media)
        XCTAssertEqual(MediaProbe.classify(prefix: Data([0, 0, 0, 24] + Array("ftypisom".utf8)), contentType: "application/octet-stream"), .media)
        XCTAssertEqual(MediaProbe.classify(prefix: Data([0x1a, 0x45, 0xdf, 0xa3]), contentType: "video/mp4"), .media)
        XCTAssertEqual(MediaProbe.classify(prefix: Data(" \n<!DOCTYPE html><html>login</html>".utf8), contentType: "video/mp4"), .webPage)
        XCTAssertEqual(MediaProbe.classify(prefix: Data("unrecognized".utf8), contentType: "application/octet-stream"), .unknown)
    }

    /// 源忽略 Range 时只返回指定前缀，且一次探测不会关闭调用者的共享会话。
    func testBoundedPrefixPreservesHeadersAndSession() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://cdn.example/large")!
        let headers = ["Cookie": "fixture=1", "Referer": "https://fixture.example/", "User-Agent": "FixtureAgent"]
        let (prefix, _) = try await MediaProbe.readPrefix(url: url, headers: headers, count: 4, session: session)
        XCTAssertEqual(prefix, Data(repeating: 0x61, count: 4))
        let kind = try await MediaProbe.classify(url: URL(string: "https://cdn.example/play?id=7")!, headers: headers, session: session)
        XCTAssertEqual(kind, .media)
    }

    /// 公网 MP4 地址返回 Matroska 也必须进入兼容播放，不再仅检测本地代理。
    @MainActor
    func testPublicDisguisedMatroskaNeedsRemux() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let channel = TVChannel(id: "fixture", name: "Fixture", group: "Test", logoURL: nil,
                                streamURL: URL(string: "https://cdn.example/disguised.mp4")!, headers: [:])
        let result = try await MediaRemuxSession.needsRemux(channel, session: session)
        XCTAssertTrue(result)
    }

    /// 不支持 Range 的源保留原生播放机会，不因为新增探测而阻断已有线路。
    @MainActor
    func testRejectedProbeFallsBackToNativePlayback() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let channel = TVChannel(id: "fixture", name: "Fixture", group: "Test", logoURL: nil,
                                streamURL: URL(string: "https://cdn.example/reject")!, headers: [:])
        let result = try await MediaRemuxSession.needsRemux(channel, session: session)
        XCTAssertFalse(result)
    }

    /// 远端忽略 Range 或返回错误起点时，不能将文件头当成其他位置的元数据。
    func testNonzeroOffsetRejectsIgnoredOrMismatchedRange() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        for path in ["disguised.mp4", "wrong-range"] {
            do {
                _ = try await MediaProbe.readPrefix(url: URL(string: "https://cdn.example/\(path)")!, headers: [:], count: 8, offset: 100, session: session)
                XCTFail("Incorrect byte range must be rejected")
            } catch { XCTAssertTrue(error is SourceParseError) }
        }
    }

    /// 每个测试使用独立会话，不修改系统 URLSession 全局配置。
    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaProbeFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MediaProbeFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = path == "/reject" ? 416 : 200
        let body: Data
        switch path {
        case "/large": body = Data(repeating: 0x61, count: 8192)
        case "/disguised.mp4": body = Data([0x1a, 0x45, 0xdf, 0xa3, 0x42])
        default: body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n".utf8)
        }
        if ["/large", "/play"].contains(path),
           (request.value(forHTTPHeaderField: "Cookie") != "fixture=1"
            || request.value(forHTTPHeaderField: "Referer") != "https://fixture.example/"
            || request.value(forHTTPHeaderField: "User-Agent") != "FixtureAgent"
            || request.value(forHTTPHeaderField: "Range") == nil) { status = 403 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: path == "/wrong-range" ? 206 : status, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream", "Content-Range": "bytes 0-7/1000"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        // 忽略 Range 且保持响应未结束；探测必须在有限前缀后返回并取消请求。
        if path != "/large" { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
