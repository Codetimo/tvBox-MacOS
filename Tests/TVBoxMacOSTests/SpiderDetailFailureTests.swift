import XCTest
@testable import TVBoxMacOS

final class SpiderDetailFailureTests: XCTestCase {
    /// 复现蜗牛 HTTP 200 + 空列表 + 登录提示，不能再丢失真正的失败原因。
    func testEmptyDetailPreservesSiteLoginMessage() {
        assertFailure(#"{"list":[],"msg":"蜗牛影视未登录，请先到配置中心登录或填写 Cookie","parse":0,"jx":0}"#,
                      contains: "蜗牛影视未登录")
    }

    /// 盘迷没有可解析网盘链接与账号未登录不同，应分别展示提供商的原因。
    func testEmptyDetailPreservesMissingShareMessage() {
        assertFailure(#"{"list":[],"msg":"没有解析到123网盘链接","parse":0,"jx":0}"#,
                      contains: "没有解析到123网盘链接")
    }

    /// 支持已有的 data/result/payload 包装，内部错误优先于外层成功提示。
    func testNestedDetailWithoutRoutesPreservesMessage() {
        assertFailure(#"{"message":"success","data":{"result":{"list":[{"vod_id":"movie-1"}],"message":"分享链接已失效"}}}"#,
                      contains: "分享链接已失效")
    }

    /// 没有业务错误的空响应仍显示明确的详情错误，不把 success 当成失败原因。
    func testEmptyDetailWithSuccessMessageUsesFallback() {
        assertFailure(#"{"list":[],"msg":"success"}"#, contains: "站点未返回所选影片的详情")
    }

    /// 业务提示不能放宽身份校验，也不能将错误影片当作同名影片播放。
    func testWrongIDRemainsRejected() {
        assertFailure(#"{"list":[{"vod_id":"wrong","vod_name":"影片","vod_play_url":"正片$opaque"}],"msg":"提示"}"#,
                      contains: "站点未返回所选影片的详情")
    }

    /// 有可用详情时忽略附加提示，并保留搜索条目的身份、站点和不透明播放 ID。
    func testPlayableDetailIgnoresInformationalMessage() throws {
        let item = summary()
        let body = #"{"list":[{"vod_id":"movie-1","vod_name":"影片","vod_play_from":"百度原画","vod_play_url":"第1集$opaque%2BID"}],"msg":"附加提示"}"#
        let detail = try SourceLoader.parseSpiderDetail(data: Data(body.utf8), item: item)
        XCTAssertEqual(detail.id, item.id)
        XCTAssertEqual(detail.vodID, item.vodID)
        XCTAssertEqual(detail.spiderSite, item.spiderSite)
        XCTAssertEqual(detail.playSources.first?.playerID, "opaque%2BID")
        XCTAssertEqual(detail.playSources.first?.flag, "百度原画")
    }

    /// 不读取用户凭据，直接验证生产详情解析入口的错误信息。
    private func assertFailure(_ body: String, contains message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SourceLoader.parseSpiderDetail(data: Data(body.utf8), item: summary()), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains(message), $0.localizedDescription, file: file, line: line)
        }
    }

    /// 使用脱敏站点构造摘要，确保回归用例与本机源库、账号无关。
    private func summary() -> TVMediaItem {
        let site = TVBoxSite(key: "fixture", name: "测试站点", adapter: "csp_Fixture",
                             spiderURL: URL(string: "https://example.com/spider.jar")!)
        return TVMediaItem(id: "stable-search-id", name: "影片", sourceName: site.name,
                           siteName: site.name, siteKey: site.key, spiderSite: site, vodID: "movie-1")
    }
}
