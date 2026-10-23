import XCTest
import AppKit
import SwiftUI
@testable import TVBoxMacOS

final class PlaybackWindowTests: XCTestCase {
    /// 连续点击播放应只更新窗口标题，继续使用原来的播放器容器。
    @MainActor func testRepeatedPresentationReusesSingleWindow() {
        _ = NSApplication.shared
        let controller = PlaybackWindowController()
        controller.present(title: "第一集", content: Text("播放器"), onClose: {})
        let original = controller.window
        controller.present(title: "第二集", content: Text("播放器"), onClose: {})
        XCTAssertTrue(controller.window === original)
        XCTAssertEqual(controller.window?.title, "第二集")
        controller.close()
        XCTAssertNil(controller.window)
    }

    /// 关闭取消解析、清空会话，且只调用一次停止播放回调。
    @MainActor func testCloseCancelsPendingResolutionAndStopsPlaybackOnce() {
        _ = NSApplication.shared
        let controller = PlaybackWindowController()
        var stopCount = 0
        let pending = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        controller.task = pending
        controller.notice = "正在解析"
        controller.channel = TVChannel(id: "fixture-live", name: "测试直播", group: "本地", logoURL: nil, streamURL: URL(string: "http://127.0.0.1/live.m3u8")!, headers: [:])
        controller.present(title: "播放", content: Text("播放器")) { stopCount += 1 }
        controller.close()
        controller.close()
        XCTAssertTrue(pending.isCancelled)
        XCTAssertNil(controller.task)
        XCTAssertNil(controller.notice)
        XCTAssertNil(controller.channel)
        XCTAssertNil(controller.window)
        XCTAssertEqual(stopCount, 1)
    }

    /// 关闭后重新播放会创建新的窗口，旧内容已经释放，避免后台重复发声。
    @MainActor func testClosedWindowCanReopenWithNewContent() {
        _ = NSApplication.shared
        let controller = PlaybackWindowController()
        controller.present(title: "旧播放", content: Text("旧播放器"), onClose: {})
        let closed = controller.window
        controller.close()
        XCTAssertNil(closed?.contentView)
        controller.present(title: "新播放", content: Text("新播放器"), onClose: {})
        XCTAssertNotNil(controller.window)
        XCTAssertFalse(controller.window === closed)
        XCTAssertEqual(controller.window?.title, "新播放")
        controller.close()
    }
}
