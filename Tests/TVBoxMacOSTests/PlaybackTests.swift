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
