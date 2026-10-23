import AVFoundation
import AppKit
import XCTest
@testable import TVBoxMacOS

final class PlayerControlsTests: XCTestCase {
    /// 普通窗口挂载后自动启用隐藏，验证鼠标/键盘唤醒和重新计时。
    @MainActor
    func testWindowedControlsAutomaticallyHideAndWakeForPlayerInput() throws {
        _ = NSApplication.shared
        let view = KeyboardPlayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        view.configureControls(compatibility: false)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.setControlsAutoHide(false); window.close() }
        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSStackView }.first)

        XCTAssertFalse(bar.isHidden)
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        XCTAssertTrue(bar.isHidden)
        // SwiftUI 的时间轴/兼容模式同步不应唤醒已经隐藏的控制栏。
        view.configureControls(compatibility: true)
        XCTAssertTrue(bar.isHidden)

        let mouse = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        NSApp.sendEvent(mouse)
        XCTAssertFalse(bar.isHidden)
        RunLoop.main.run(until: Date().addingTimeInterval(1.7))
        NSApp.sendEvent(mouse)
        RunLoop.main.run(until: Date().addingTimeInterval(1.7))
        XCTAssertFalse(bar.isHidden, "每次操作都应重新计算三秒空闲时间")
        RunLoop.main.run(until: Date().addingTimeInterval(1.7))
        XCTAssertTrue(bar.isHidden)

        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        NSApp.sendEvent(key)
        XCTAssertFalse(bar.isHidden)
        view.setControlsAutoHide(false)
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        XCTAssertFalse(bar.isHidden, "关闭监听后控制栏恢复可见，不再收到隐藏计时")
    }

    /// 其他窗口的操作不能唤醒控制栏；移除视图时恢复可见状态并清理监听。
    @MainActor
    func testControlsIgnoreOtherWindowAndCleanUpOnDetach() throws {
        _ = NSApplication.shared
        let view = KeyboardPlayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        view.configureControls(compatibility: false)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close(); other.close() }
        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSStackView }.first)
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        XCTAssertTrue(bar.isHidden)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: other.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        NSApp.sendEvent(key)
        XCTAssertTrue(bar.isHidden)
        view.removeFromSuperview()
        XCTAssertFalse(bar.isHidden)
    }

    /// 小屏只响应播放区域与自身焦点，搜索等区域的输入不会唤醒控件。
    @MainActor
    func testWindowedControlsIgnoreInputOutsidePlayer() throws {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let view = KeyboardPlayerView(frame: NSRect(x: 100, y: 100, width: 800, height: 450))
        container.addSubview(view)
        let field = NSTextField(frame: NSRect(x: 100, y: 600, width: 400, height: 30))
        container.addSubview(field)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { view.setControlsAutoHide(false); window.close() }
        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSStackView }.first)
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        XCTAssertTrue(bar.isHidden)

        let outsideMouse = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 50, y: 650),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        NSApp.sendEvent(outsideMouse)
        XCTAssertTrue(bar.isHidden)
        // 文本框实际由窗口共享的 NSTextView 编辑器接收键盘；离屏测试直接设置该焦点。
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field))
        XCTAssertTrue(window.makeFirstResponder(editor))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        NSApp.sendEvent(key)
        XCTAssertTrue(bar.isHidden)

        XCTAssertTrue(window.makeFirstResponder(view))
        NSApp.sendEvent(key)
        XCTAssertFalse(bar.isHidden)
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        XCTAssertTrue(bar.isHidden)
        let insideMouse = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 500, y: 300),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        NSApp.sendEvent(insideMouse)
        XCTAssertFalse(bar.isHidden)
    }

    /// 缩放离屏窗口后，进度、音量与操作按钮都应保持在播放器可视宽度内。
    @MainActor
    func testControlsRemainInsidePlayerAfterResize() {
        _ = NSApplication.shared
        let view = KeyboardPlayerView(frame: NSRect(x: 0, y: 0, width: 1200, height: 450))
        view.configureControls(compatibility: false)
        view.player = AVPlayer()
        view.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.player = nil; window.close() }

        for width in [600.0, 1200.0, 400.0, 1200.0] {
            window.setContentSize(NSSize(width: width, height: 450))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.bounds.width, width, accuracy: 0.5)
            var pendingViews = view.subviews
            var controlCount = 0
            while let child = pendingViews.popLast() {
                pendingViews.append(contentsOf: child.subviews)
                guard child is NSButton || child is NSSlider else { continue }
                controlCount += 1
                let frame = child.convert(child.bounds, to: view)
                let context = "\(type(of: child)) at player width \(width): \(frame)"
                XCTAssertGreaterThanOrEqual(frame.minX, view.bounds.minX - 0.5, context)
                XCTAssertLessThanOrEqual(frame.maxX, view.bounds.maxX + 0.5, context)
            }
            XCTAssertGreaterThan(controlCount, 0, "Expected playback controls to exist")
        }
    }

    func testCompatibilityProgressUsesSourceDurationInsteadOfGeneratedSegments() {
        let timeline = PlayerTimelineState(sourceDuration: 1200, itemDuration: 60, compatibility: true,
                                           currentTime: 30, offset: 0, loadedRanges: [range(0, 60)])
        XCTAssertEqual(timeline.duration, 1200)
        XCTAssertEqual(timeline.currentTime, 30)
        XCTAssertEqual(timeline.seekTarget(fraction: 0.75), 900)
        XCTAssertEqual(timeline.bufferedRanges.count, 1)
        XCTAssertEqual(timeline.bufferedRanges[0].upperBound, 0.05, accuracy: 0.0001)
    }

    func testCompatibilityUnknownDurationNeverUsesCachedLengthAsTotal() {
        let timeline = PlayerTimelineState(sourceDuration: nil, itemDuration: 60, compatibility: true,
                                           currentTime: 30, offset: 0, loadedRanges: [range(0, 60)])
        XCTAssertNil(timeline.duration)
        XCTAssertNil(timeline.seekTarget(fraction: 0.5))
        XCTAssertTrue(timeline.bufferedRanges.isEmpty)
    }

    func testNativeVideoUsesFiniteItemDuration() {
        let timeline = PlayerTimelineState(sourceDuration: nil, itemDuration: 1800, compatibility: false,
                                           currentTime: 120, offset: 0, loadedRanges: [])
        XCTAssertEqual(timeline.duration, 1800)
        XCTAssertEqual(timeline.seekTarget(fraction: 0.5), 900)
    }

    func testOffsetMapsRestartedPlaybackAndBufferedSegmentsOntoWholeVideo() {
        let timeline = PlayerTimelineState(sourceDuration: 1000, itemDuration: 60, compatibility: true,
                                           currentTime: 20, offset: 500, loadedRanges: [range(0, 40), range(50, 10)])
        XCTAssertEqual(timeline.currentTime, 520)
        XCTAssertEqual(timeline.bufferedRanges, [0.5...0.54, 0.55...0.56])
        XCTAssertEqual(timeline.seekTarget(fraction: 0.1), 100)
    }

    func testInvalidTimesAndBufferRangesAreExcluded() {
        let timeline = PlayerTimelineState(sourceDuration: .infinity, itemDuration: .nan, compatibility: false,
                                           currentTime: .nan, offset: .infinity, loadedRanges: [.invalid])
        XCTAssertNil(timeline.duration)
        XCTAssertEqual(timeline.currentTime, 0)
        XCTAssertTrue(timeline.bufferedRanges.isEmpty)
        XCTAssertNil(timeline.seekTarget(fraction: .nan))
    }

    func testClampsOutOfBoundsBuffersAndSeekFraction() {
        let timeline = PlayerTimelineState(sourceDuration: 100, itemDuration: nil, compatibility: true,
                                           currentTime: 120, offset: 0, loadedRanges: [range(-10, 30), range(90, 30), range(150, 10)])
        XCTAssertEqual(timeline.currentTime, 100)
        XCTAssertEqual(timeline.bufferedRanges, [0...0.2, 0.9...1])
        XCTAssertEqual(timeline.seekTarget(fraction: -1), 0)
        XCTAssertEqual(timeline.seekTarget(fraction: 2), 100)
    }

    func testTimeFormattingHandlesHoursAndUnknownTimes() {
        XCTAssertEqual(PlayerTimelineState.formattedTime(61), "01:01")
        XCTAssertEqual(PlayerTimelineState.formattedTime(3661), "1:01:01")
        XCTAssertEqual(PlayerTimelineState.formattedTime(.nan), "--:--")
        XCTAssertEqual(PlayerTimelineState.formattedTime(.infinity), "--:--")
    }

    /// 创建测试缓存区间，数值使用秒，与媒体播放器的时间单位一致。
    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
    }
}
