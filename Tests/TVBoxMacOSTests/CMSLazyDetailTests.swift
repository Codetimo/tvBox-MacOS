import XCTest
@testable import TVBoxMacOS

final class CMSLazyDetailTests: XCTestCase {
    /// 搜索只返回摘要，打开详情时仍携带身份参数和 CMS 兼容请求头。
    func testLazySearchAndDetailPreserveRequestContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LazyCMSFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let loader = SourceLoader(session: session)
        let site = TVBoxSite(key: "cms", name: "测试CMS", api: URL(string: "https://lazy-cms.example/api?token=AbC%2B123")!)
        let results = try await loader.search(site: site, keyword: "影片", enrichDetails: false)
        let summary = try XCTUnwrap(results.first)
        XCTAssertTrue(summary.playSources.isEmpty, "Search must not fetch lazy details")
        let detail = try await loader.loadCMSDetail(item: summary)
        XCTAssertEqual(detail.id, summary.id)
        XCTAssertEqual(detail.vodID, "movie-1")
        XCTAssertEqual(detail.playSources.first?.url?.absoluteString, "https://cdn.example/movie.m3u8")
    }

    /// 惰性详情不能通过同名结果接受另一个 vod_id。
    func testLazyDetailRejectsWrongIDWithSameTitle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LazyCMSFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let item = TVMediaItem(id: "original-id", name: "影片", detailURL: URL(string: "https://lazy-cms.example/wrong?ids=movie-1")!, siteKey: "cms", vodID: "movie-1")
        do {
            _ = try await SourceLoader(session: session).loadCMSDetail(item: item)
            XCTFail("Mismatched detail must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("所选影片"))
        }
    }
}

/// 详情端要求与搜索一致的内容协商/浏览器请求头，用来捕获惰性加载引入的协议回归。
private final class LazyCMSFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lazy-cms.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 根据查询参数返回摘要或详情，并保留明确错误 ID 的独立响应路径。
    override func startLoading() {
        guard let url = request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let wrong = url.path == "/wrong"
        let isDetail = query.contains { $0.name == "ids" }
        let valid = wrong || (query.first { $0.name == "token" }?.value == "AbC+123"
            && request.value(forHTTPHeaderField: "Accept") == "application/json,text/plain,*/*"
            && request.value(forHTTPHeaderField: "User-Agent")?.contains("AppleWebKit") == true)
        let body: String
        if wrong {
            body = #"{"list":[{"vod_id":"wrong-id","vod_name":"影片","vod_play_url":"正片$https://cdn.example/wrong.m3u8"}]}"#
        } else if isDetail {
            body = #"{"list":[{"vod_id":"movie-1","vod_name":"影片","vod_play_url":"正片$https://cdn.example/movie.m3u8"}]}"#
        } else {
            body = #"{"list":[{"vod_id":"movie-1","vod_name":"影片"}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: valid ? 200 : 406,
                                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
