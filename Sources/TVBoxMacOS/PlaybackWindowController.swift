import AppKit
import SwiftUI

/// 持有唯一播放窗口及其解析会话，避免每次播放都新建播放器窗口。
@MainActor
final class PlaybackWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var channel: TVChannel?
    @Published var movie: TVMediaItem?
    @Published var source: TVPlaySource?
    @Published var notice: String?
    var task: Task<Void, Never>?
    private(set) var window: NSWindow?
    private var onClose: (() -> Void)?

    /// 首次播放创建窗口，后续选集、换源或直播播放复用已有窗口。
    func present<Content: View>(title: String, content: Content, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let window {
            window.title = title
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier("TVBoxPlaybackWindow")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 540)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 主窗口退出时也走相同关闭路径，确保取消解析及释放播放资源。
    func close() {
        window?.close()
    }

    /// 关闭立即取消未完成解析，阻止解析结果在不可见窗口继续播放。
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        task?.cancel()
        task = nil
        let completion = onClose
        onClose = nil
        completion?()
        closingWindow.contentView = nil
        closingWindow.delegate = nil
        window = nil
        channel = nil
        movie = nil
        source = nil
        notice = nil
    }
}
