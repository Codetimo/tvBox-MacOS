import XCTest
import AVKit
@testable import TVBoxMacOS

final class PlaybackTests: XCTestCase {
    func testPlaybackHeadersSupplyBrowserIdentityAndKeepSourceOverrides() {
        let headers = playbackHTTPHeaders(overrides: ["User-Agent": "FixtureAgent", "Referer": "https://example.com/"])
        XCTAssertEqual(headers["User-Agent"], "FixtureAgent")
        XCTAssertEqual(headers["Referer"], "https://example.com/")
        XCTAssertEqual(headers["Accept"], "*/*")
    }

    @MainActor
    func testPlaybackCoordinatorExposesResolutionErrors() {
        let coordinator = PlaybackCoordinator()
        coordinator.showError("播放解析失败：站点需要授权")
        XCTAssertEqual(coordinator.errorMessage, "播放解析失败：站点需要授权")
        coordinator.clearError()
        XCTAssertNil(coordinator.errorMessage)
    }
    func testRouteNamesPreserveEpisodesAndSupportCachedCMSNames() {
        let spider = TVPlaySource(name: "夸克原画 · 第03集", url: nil, playerID: "opaque", flag: "夸克原画")
        XCTAssertEqual(spider.routeName, "夸克原画")
        XCTAssertEqual(spider.episodeName, "第03集")
        let cms = TVPlaySource(name: "高清 · 03", url: URL(string: "https://example.com/3.mp4"))
        XCTAssertEqual(cms.routeName, "高清")
        XCTAssertEqual(cms.episodeName, "03")
        let unnamed = TVPlaySource(name: "第01集", url: nil)
        XCTAssertEqual(unnamed.routeName, "默认线路")
        XCTAssertEqual(unnamed.episodeName, "第01集")
    }

    func testPlaybackErrorsDoNotExposeSignedURLs() {
        let channel = TVChannel(id: "fixture", name: "影片", group: "夸克原画 · 第03集", logoURL: nil,
                                streamURL: URL(string: "http://127.0.0.1:21611/kaiser?token=private-signature")!, headers: [:])
        let failure = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: channel.streamURL.absoluteString])
        let message = playbackFailureMessage(error: failure, channel: channel)
        XCTAssertFalse(message.contains("private-signature"))
        XCTAssertTrue(message.contains("重新解析"))
        XCTAssertTrue(message.contains("第03集"))
    }

    func testTLSErrorsExplainSecureConnectionFailureWithoutLeakingURLs() {
        let channel = TVChannel(id: "tls", name: "直播", group: "直播线路", logoURL: nil,
                                streamURL: URL(string: "https://example.com/live?token=private-signature")!, headers: [:])
        for code in [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted] {
            let tls = NSError(domain: NSURLErrorDomain, code: code,
                              userInfo: [NSLocalizedDescriptionKey: channel.streamURL.absoluteString])
            let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
                                  userInfo: [NSUnderlyingErrorKey: tls])
            for error in [tls, wrapped] {
                let message = playbackFailureMessage(error: error, channel: channel)
                XCTAssertTrue(message.contains("安全连接"))
                XCTAssertTrue(message.contains("TLS"))
                XCTAssertTrue(message.contains("NSURLErrorDomain (\(code))"))
                XCTAssertFalse(message.contains("private-signature"))
                XCTAssertFalse(message.contains("关闭证书"))
            }
        }
    }

    /// 同一个 ATS 错误在 URLSession 与 AVFoundation 中使用不同 domain，均应显示真实原因。
    func testTransportSecurityErrorsExplainAppConfigurationWithoutLeakingURLs() {
        let channel = TVChannel(id: "ats", name: "CCTV2", group: "央视IPV4", logoURL: nil,
                                streamURL: URL(string: "http://example.com/live?token=private-signature")!, headers: [:])
        for domain in [NSURLErrorDomain, NSOSStatusErrorDomain] {
            let underlying = NSError(domain: domain, code: NSURLErrorAppTransportSecurityRequiresSecureConnection,
                                     userInfo: [NSLocalizedDescriptionKey: channel.streamURL.absoluteString])
            let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
                                  userInfo: [NSUnderlyingErrorKey: underlying])
            for error in [underlying, wrapped] {
                let message = playbackFailureMessage(error: error, channel: channel)
                XCTAssertTrue(message.contains("网络安全配置"))
                XCTAssertTrue(message.contains("\(domain) (-1022)"))
                XCTAssertFalse(message.contains("private-signature"))
                XCTAssertFalse(message.contains("已失效"))
            }
        }
    }

    @MainActor
    func testFullscreenPlayerFillsContentAfterWindowResize() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let player = AVPlayer()
        let controller = FullscreenPlayerController(player: player, screen: screen, onCommand: nil)
        let window = try XCTUnwrap(controller.window)
        let container = try XCTUnwrap(window.contentView)
        for size in [NSSize(width: 800, height: 450), screen.frame.size, NSSize(width: 1200, height: 800)] {
            window.setContentSize(size)
            container.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.playerView.frame, container.bounds)
            XCTAssertTrue(controller.playerView.player === player)
            XCTAssertEqual(window.backgroundColor, .black)
        }
        controller.close()
    }

}
