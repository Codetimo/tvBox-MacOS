import AVKit
import Combine
import Foundation
import SwiftUI
import WebKit
import os

enum PlaybackSettings {
    static let seekStepKey = "playbackSeekStepSeconds"
    static let defaultSeekStepSeconds = 10.0

    /// 读取并校验用户设置的左右方向键步长。
    static var seekStepSeconds: Double {
        let configured = UserDefaults.standard.double(forKey: seekStepKey)
        return configured > 0 ? configured : defaultSeekStepSeconds
    }
}

/// 播放器视图向 SwiftUI 层发送的键盘操作。
enum PlaybackCommand {
    case seek(Double)
    case seekTo(Double)
    case adjustVolume(Float)
}

/// 为 AVPlayer 请求补齐常见 CDN 所需的客户端请求头，同时保留源站自定义值。
func playbackHTTPHeaders(overrides: [String: String] = [:]) -> [String: String] {
    var headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
        "Accept": "*/*"
    ]
    overrides.forEach { headers[$0.key] = $0.value }
    return headers
}

/// 错误只展示可操作的说明及错误码，避免签名 URL 和 Cookie 出现在弹层中。
func playbackFailureMessage(error: Error?, channel: TVChannel) -> String {
    let failure = error as NSError?
    let reason: String
    switch failure?.code {
    case AVError.fileFormatNotRecognized.rawValue, AVError.decoderNotFound.rawValue:
        reason = "当前系统播放器无法识别这条线路的媒体格式，请切换其他画质或线路。"
    default:
        reason = "媒体地址无法打开，可能已失效或返回了不受支持的媒体。请重新解析播放，或在下方切换线路。"
    }
    let code = failure.map { "\n错误码：\($0.domain) (\($0.code))" } ?? ""
    return "\(reason)\n线路：\(channel.group)\(code)"
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var webURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var preparationMessage: String?
    @Published private(set) var compatibilityNotice: String?
    @Published private(set) var sourceDuration: Double?
    @Published private(set) var timelineOffset = 0.0
    private var originalChannel: TVChannel?
    private var pendingSeekTime: Double?
    private var itemStatusObservation: AnyCancellable?
    private var preparationTask: Task<Void, Never>?
    private var remuxSession: MediaRemuxSession?
    private var remuxMonitorTask: Task<Void, Never>?
    private var generation = UUID()

    /// 新线路启动失败时通知界面尝试同集备用源；已经播放后的错误不自动跳回开头。
    func play(_ channel: TVChannel, onStartupFailure: (() -> Void)? = nil) {
        guard ["http", "https"].contains(channel.streamURL.scheme?.lowercased()) else {
            errorMessage = "播放地址必须使用 HTTP 或 HTTPS。"
            return
        }
        stop()
        errorMessage = nil
        webURL = nil
        originalChannel = channel

        let attempt = generation
        preparationMessage = "正在检查媒体…"
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                var playable = channel
                if try await MediaRemuxSession.needsRemux(channel) {
                    try Task.checkCancellation()
                    preparationMessage = "正在准备 MKV 兼容播放…"
                    let session = try await MediaRemuxSession.start(channel: channel)
                    guard !Task.isCancelled, generation == attempt else { session.stop(); return }
                    remuxSession = session
                    sourceDuration = session.sourceDuration
                    timelineOffset = session.startTime
                    compatibilityNotice = "MKV 兼容播放：进度按原片总时长显示，灰条表示缓存；跳转未缓存位置时需要重新加载。"
                    monitorRemux(session, attempt: attempt)
                    playable = TVChannel(id: channel.id, name: channel.name, group: channel.group,
                                         logoURL: channel.logoURL, streamURL: session.playbackURL, headers: [:])
                }
                try Task.checkCancellation()
                guard generation == attempt else { return }
                preparationMessage = nil
                startNative(playable, onStartupFailure: onStartupFailure)
            } catch {
                guard !Task.isCancelled, generation == attempt else { return }
                preparationMessage = nil
                errorMessage = (error as? SourceParseError)?.localizedDescription
                    ?? "媒体连接失败，请重新解析播放或切换其他线路。"
                onStartupFailure?()
            }
        }
    }

    /// 原生播放器和本地转封装结果共用状态监听及错误处理。
    private func startNative(_ channel: TVChannel, onStartupFailure: (() -> Void)?, reusePlayer: AVPlayer? = nil, resumePlayback: Bool = true) {
        // Some CMS/CDN endpoints return 404 to AVPlayer's default client identity.
        // Keep source-provided headers authoritative while supplying a browser-like UA.
        let headers = playbackHTTPHeaders(overrides: channel.headers)
        let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: channel.streamURL, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        var hasBeenReady = false
        var failureReported = false
        itemStatusObservation = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self, weak item] status in
            guard let self, let item, self.player?.currentItem === item else { return }
            if status == .readyToPlay { hasBeenReady = true }
            guard status == .failed, !failureReported else { return }
            failureReported = true
            self.remuxMonitorTask?.cancel()
            self.remuxSession?.stop()
            self.remuxSession = nil
            self.errorMessage = playbackFailureMessage(error: item.error, channel: channel)
            let failure = item.error as NSError?
            Logger(subsystem: "com.codetimo.tvbox-macos", category: "Playback").error(
                "Playback failed: route=\(channel.group, privacy: .public) domain=\(failure?.domain ?? "unknown", privacy: .public) code=\(failure?.code ?? 0)")
            if !hasBeenReady { onStartupFailure?() }
        }
        if let reusePlayer {
            reusePlayer.replaceCurrentItem(with: item)
            player = reusePlayer
        } else {
            player = AVPlayer(playerItem: item)
        }
        if resumePlayback { player?.play() }
    }

    func stop() {
        generation = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        remuxMonitorTask?.cancel()
        remuxMonitorTask = nil
        remuxSession?.stop()
        remuxSession = nil
        compatibilityNotice = nil
        sourceDuration = nil
        timelineOffset = 0
        originalChannel = nil
        pendingSeekTime = nil
        preparationMessage = nil
        player?.pause()
        itemStatusObservation = nil
        player = nil
        webURL = nil
    }

    /// 在应用内打开第三方播放页，避免点击线路后界面没有反馈。
    func openWeb(_ url: URL) {
        stop()
        webURL = url
        errorMessage = nil
    }

    /// 清除当前播放错误提示，便于用户继续选择其他频道。
    func clearError() {
        errorMessage = nil
    }

    /// 显示解析阶段的播放错误。解析播放地址发生在 PlaybackCoordinator 之外，
    /// 也必须通过同一个错误提示出口反馈给用户，避免错误只写到被弹窗遮住的状态栏。
    func showError(_ message: String) {
        // 清理上一次播放，避免解析新线路失败后旧音视频仍在后台继续播放。
        stop()
        errorMessage = message
    }

    /// 相对快进与进度条共用完整影片时间轴，避免动态 HLS 的缓存窗口充当总长。
    func seek(by seconds: Double) {
        guard seconds.isFinite, let player else { return }
        let current = player.currentTime().seconds
        seek(to: (pendingSeekTime ?? ((current.isFinite ? current : 0) + timelineOffset)) + seconds)
    }

    /// 已缓存片段直接定位；兼容流的未缓存位置从原片重新生成，复用播放器保留全屏和音量。
    func seek(to seconds: Double) {
        guard seconds.isFinite, let player, let item = player.currentItem else { return }
        if remuxSession != nil, let channel = originalChannel {
            let upper = sourceDuration.map { max(0, $0 - 0.1) } ?? .greatestFiniteMagnitude
            let target = min(max(seconds, 0), upper)
            let localTarget = target - timelineOffset
            let cached = item.seekableTimeRanges.contains {
                let range = $0.timeRangeValue
                return localTarget >= range.start.seconds && localTarget <= CMTimeRangeGetEnd(range).seconds
            }
            if cached {
                if preparationMessage != nil {
                    preparationTask?.cancel()
                    generation = UUID()
                    preparationMessage = nil
                    pendingSeekTime = nil
                    if let session = remuxSession { monitorRemux(session, attempt: generation) }
                }
                player.seek(to: CMTime(seconds: localTarget, preferredTimescale: 600))
                return
            }
            restartRemux(channel: channel, at: target, player: player)
            return
        }
        let duration = item.duration.seconds
        let range = item.seekableTimeRanges.last?.timeRangeValue
        let lower = duration.isFinite && duration > 0 ? 0 : (range?.start.seconds ?? 0)
        let upper = duration.isFinite && duration > 0 ? duration : (range.map { CMTimeRangeGetEnd($0).seconds } ?? 0)
        guard lower.isFinite, upper.isFinite, upper > lower else { return }
        player.seek(to: CMTime(seconds: min(max(seconds, lower), upper), preferredTimescale: 600))
    }

    /// 取消过时的跳转任务，只有最新请求能替换播放项目；准备失败时保留原有会话。
    private func restartRemux(channel: TVChannel, at target: Double, player: AVPlayer) {
        preparationTask?.cancel()
        remuxMonitorTask?.cancel()
        generation = UUID()
        let attempt = generation
        let duration = sourceDuration
        pendingSeekTime = target
        preparationMessage = "正在加载跳转位置…"
        errorMessage = nil
        preparationTask = Task { [weak self, weak player] in
            guard let self, let player else { return }
            do {
                let session = try await MediaRemuxSession.start(channel: channel, startTime: target, sourceDuration: duration)
                guard !Task.isCancelled, generation == attempt else { session.stop(); return }
                let shouldResume = player.timeControlStatus != .paused
                remuxSession?.stop()
                remuxSession = session
                sourceDuration = session.sourceDuration
                timelineOffset = session.startTime
                pendingSeekTime = nil
                preparationMessage = nil
                let playable = TVChannel(id: channel.id, name: channel.name, group: channel.group,
                                         logoURL: channel.logoURL, streamURL: session.playbackURL, headers: [:])
                startNative(playable, onStartupFailure: nil, reusePlayer: player, resumePlayback: shouldResume)
                monitorRemux(session, attempt: attempt)
            } catch {
                guard !Task.isCancelled, generation == attempt else { return }
                preparationMessage = nil
                pendingSeekTime = nil
                errorMessage = (error as? SourceParseError)?.localizedDescription ?? "跳转位置加载失败，请重试或切换线路。"
                if let session = remuxSession { monitorRemux(session, attempt: attempt) }
            }
        }
    }

    /// 只监视当前会话，切换集数或跳转后旧任务不会中断新播放。
    private func monitorRemux(_ session: MediaRemuxSession, attempt: UUID) {
        remuxMonitorTask?.cancel()
        remuxMonitorTask = Task { [weak self, weak session] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, let session, self.generation == attempt else { return }
                if let code = session.failureExitCode {
                    self.showError("兼容播放的数据读取中断（退出码 \(code)），请重新解析播放或切换线路。")
                    return
                }
            }
        }
    }

    /// 按固定的 5% 步长调整音量，并限制在静音到最大音量之间。
    func adjustVolume(by amount: Float) {
        guard let player else { return }
        guard amount.isFinite else { return }
        player.volume = min(max(player.volume + amount, 0), 1)
        player.isMuted = false
    }
}

/// 使用 AppKit 的 AVPlayerView 承载视频，绕开 macOS 13/14 上 SwiftUI VideoPlayer 的布局崩溃。
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    let usesCompatibilityControls: Bool
    var sourceDuration: Double? = nil
    var timelineOffset: Double = 0
    var preparationMessage: String? = nil
    let onCommand: (PlaybackCommand) -> Void

    func makeNSView(context: Context) -> KeyboardPlayerView {
        let view = KeyboardPlayerView()
        view.sourceDuration = sourceDuration
        view.timelineOffset = timelineOffset
        view.preparationMessage = preparationMessage
        view.configureControls(compatibility: usesCompatibilityControls)
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.autoresizingMask = [.width, .height]
        view.player = player
        view.onCommand = onCommand
        return view
    }

    /// 使用 SwiftUI 提议尺寸，避免底部控件的首选宽度撑大窄窗口中的播放器和选集。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeyboardPlayerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    /// SwiftUI 移除播放器时关闭独立全屏窗口，避免残留声音或悬空视图。
    static func dismantleNSView(_ nsView: KeyboardPlayerView, coordinator: ()) {
        nsView.closeFullscreen()
        nsView.player = nil
    }

    func updateNSView(_ nsView: KeyboardPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.onCommand = onCommand
        nsView.sourceDuration = sourceDuration
        nsView.timelineOffset = timelineOffset
        nsView.preparationMessage = preparationMessage
        nsView.configureControls(compatibility: usesCompatibilityControls)
        nsView.synchronizeFullscreen()
    }
}

/// 原视频时间轴独立于 AVPlayer 当前已生成、已下载的媒体片段。
struct PlayerTimelineState {
    let duration: Double?
    let currentTime: Double
    let bufferedRanges: [ClosedRange<Double>]

    /// 兼容播放只相信原文件时长，不能用动态 HLS 的片段长度冒充整片长度。
    init(sourceDuration: Double?, itemDuration: Double?, compatibility: Bool,
         currentTime: Double, offset: Double, loadedRanges: [CMTimeRange]) {
        let validSourceDuration = sourceDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let validItemDuration = itemDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let duration = validSourceDuration ?? (compatibility ? nil : validItemDuration)
        self.duration = duration
        let safeOffset = offset.isFinite ? max(0, offset) : 0
        let actualTime = (currentTime.isFinite ? max(0, currentTime) : 0) + safeOffset
        self.currentTime = duration.map { min(actualTime, $0) } ?? actualTime
        self.bufferedRanges = loadedRanges.compactMap { range in
            guard let duration else { return nil }
            let start = range.start.seconds + safeOffset
            let end = CMTimeRangeGetEnd(range).seconds + safeOffset
            guard start.isFinite, end.isFinite, end > start else { return nil }
            let lower = min(max(start / duration, 0), 1)
            let upper = min(max(end / duration, 0), 1)
            return upper > lower ? lower...upper : nil
        }
    }

    /// 绝对跳转按整片比例计算，缓存范围只影响展示，不限制用户选择的目标。
    func seekTarget(fraction: Double) -> Double? {
        guard let duration, fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1) * duration
    }

    /// 长视频使用小时格式，避免把 90 分钟显示成容易误读的分钟数。
    static func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "--:--" }
        let value = Int(seconds)
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// 拖动过程中保留用户选择的位置，不让定时刷新把滑块拉回播放位置。
private final class PlayerTrackingSlider: NSSlider {
    private(set) var isScrubbing = false

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        defer { isScrubbing = false }
        super.mouseDown(with: event)
    }
}

/// 缓存条仅展示实际 loadedTimeRanges，与播放进度滑块使用同一个完整时间轴。
private final class PlayerBufferBar: NSView {
    var ranges: [ClosedRange<Double>] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.6).setFill()
        for range in ranges {
            let rect = NSRect(x: bounds.minX + bounds.width * range.lowerBound, y: bounds.minY,
                              width: bounds.width * (range.upperBound - range.lowerBound), height: bounds.height)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// 接收播放器快捷键，并在需要时切换当前播放器视图的全屏模式。
final class KeyboardPlayerView: AVPlayerView {
    var onCommand: ((PlaybackCommand) -> Void)?
    var onFullscreenExit: (() -> Void)?
    var sourceDuration: Double?
    var timelineOffset: Double = 0
    var preparationMessage: String? = nil
    private var fullscreenController: FullscreenPlayerController?
    private(set) var usesCompatibilityControls = false
    private var controlsBar: NSStackView?
    private var controlsTimer: Timer?
    private var progressSlider: PlayerTrackingSlider?
    private var bufferBar: PlayerBufferBar?
    private var playPauseButton: NSButton?
    private var volumeSlider: PlayerTrackingSlider?
    private var muteButton: NSButton?
    private var timeLabel: NSTextField?

    deinit { controlsTimer?.invalidate() }

    /// 普通和兼容播放共享底部控件，避免动态 HLS 时长触发系统浮动控件异常。
    func configureControls(compatibility: Bool) {
        usesCompatibilityControls = compatibility
        controlsStyle = .none
        if controlsBar == nil { buildControls() }
        if window == nil {
            controlsTimer?.invalidate()
            controlsTimer = nil
        } else if controlsTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateControls() }
            RunLoop.main.add(timer, forMode: .common)
            controlsTimer = timer
        }
        updateControls()
    }

    /// 两行布局为进度保留伸缩空间，音量和时间不再挤占滑块宽度。
    private func buildControls() {
        let backward = controlButton(symbol: "gobackward.10", label: "后退 10 秒", action: #selector(seekBackward))
        let pause = controlButton(symbol: "play.fill", label: "播放或暂停", action: #selector(togglePause))
        let forward = controlButton(symbol: "goforward.10", label: "前进 10 秒", action: #selector(seekForward))
        let fullscreen = controlButton(symbol: "arrow.up.left.and.arrow.down.right", label: "进入或退出全屏（Enter）", action: #selector(toggleFullscreen))
        let slider = PlayerTrackingSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(scrub))
        slider.isContinuous = false
        slider.setAccessibilityLabel("整片播放进度")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buffer = PlayerBufferBar()
        buffer.toolTip = "灰色为已缓存片段；拖动上方进度条可跳转到整片任意位置"
        let timeline = NSStackView(views: [slider, buffer])
        timeline.orientation = .vertical
        timeline.distribution = .fill
        timeline.setHuggingPriority(.defaultLow, for: .horizontal)
        timeline.alignment = .leading
        timeline.spacing = 1
        let transport = NSStackView(views: [backward, pause, forward, timeline, fullscreen])
        transport.spacing = 8
        transport.distribution = .fill
        transport.setHuggingPriority(.defaultLow, for: .horizontal)
        let mute = controlButton(symbol: "speaker.wave.2.fill", label: "静音或恢复声音", action: #selector(toggleMute))
        let volume = PlayerTrackingSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(changeVolume))
        volume.isContinuous = true
        volume.setAccessibilityLabel("音量")
        volume.toolTip = "调节音量（↑ / ↓）"
        let time = NSTextField(labelWithString: "00:00 / 总时长未知")
        time.textColor = .white
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.lineBreakMode = .byTruncatingMiddle
        time.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let details = NSStackView(views: [mute, volume, spacer, time])
        details.spacing = 8
        details.distribution = .fill
        details.setHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [transport, details])
        bar.orientation = .vertical
        bar.distribution = .fill
        bar.alignment = .leading
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        bar.layer?.cornerRadius = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        let preferredWidth = bar.widthAnchor.constraint(equalToConstant: 780)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            preferredWidth,
            transport.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -24),
            details.widthAnchor.constraint(equalTo: transport.widthAnchor),
            slider.widthAnchor.constraint(equalTo: timeline.widthAnchor),
            buffer.widthAnchor.constraint(equalTo: timeline.widthAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            buffer.heightAnchor.constraint(equalToConstant: 3),
            volume.widthAnchor.constraint(equalToConstant: 80)
        ])
        controlsBar = bar
        progressSlider = slider
        bufferBar = buffer
        playPauseButton = pause
        volumeSlider = volume
        muteButton = mute
        timeLabel = time
    }

    /// 按钮使用系统矢量图标，窗口和屏幕缩放时保持清晰。
    private func controlButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    /// 生成原视频时间轴，完整时长和已缓存片段严格分开。
    private func timelineState(for player: AVPlayer) -> PlayerTimelineState {
        PlayerTimelineState(sourceDuration: sourceDuration, itemDuration: player.currentItem?.duration.seconds,
                            compatibility: usesCompatibilityControls, currentTime: player.currentTime().seconds,
                            offset: timelineOffset, loadedRanges: player.currentItem?.loadedTimeRanges.map(\.timeRangeValue) ?? [])
    }

    /// 定时同步播放、缓存和音量状态，键盘与按钮操作共享同一个 AVPlayer。
    private func updateControls() {
        guard let player else { return }
        playPauseButton?.image = NSImage(systemSymbolName: player.rate > 0 ? "pause.fill" : "play.fill", accessibilityDescription: player.rate > 0 ? "暂停" : "播放")
        let timeline = timelineState(for: player)
        let total = timeline.duration.map(PlayerTimelineState.formattedTime) ?? (usesCompatibilityControls ? "总时长未知" : "直播 / 时长未知")
        timeLabel?.stringValue = preparationMessage ?? "\(PlayerTimelineState.formattedTime(timeline.currentTime)) / \(total)"
        timeLabel?.toolTip = timeLabel?.stringValue
        progressSlider?.isEnabled = timeline.duration != nil
        progressSlider?.toolTip = timeline.duration != nil ? "按整片时间跳转；灰色细条表示已缓存片段" : "尚未取得完整时长，暂不可按比例跳转"
        if progressSlider?.isScrubbing != true {
            progressSlider?.doubleValue = timeline.duration.map { timeline.currentTime / $0 } ?? 0
        }
        bufferBar?.ranges = timeline.bufferedRanges
        if volumeSlider?.isScrubbing != true { volumeSlider?.doubleValue = Double(player.volume) }
        muteButton?.image = NSImage(systemSymbolName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: player.isMuted ? "恢复声音" : "静音")
    }

    /// 自定义暂停按钮不重新创建播放器。
    @objc private func togglePause() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
        updateControls()
    }

    /// 小步调整与键盘操作使用同一入口。
    @objc private func seekBackward() { onCommand?(.seek(-10)) }
    /// 向前跳转沿用协调器的跨缓存处理。
    @objc private func seekForward() { onCommand?(.seek(10)) }

    /// 将滑块位置转换为原视频的绝对时间，交由协调器处理尚未缓存的区域。
    @objc private func scrub() {
        guard let player, let slider = progressSlider,
              let target = timelineState(for: player).seekTarget(fraction: slider.doubleValue) else { return }
        onCommand?(.seekTo(target))
    }

    /// 静音保留原音量，恢复声音时可继续使用之前的音量设置。
    @objc private func toggleMute() {
        guard let player else { return }
        if player.volume == 0 { player.volume = 0.5; player.isMuted = false }
        else { player.isMuted.toggle() }
        updateControls()
    }

    /// 调节音量主动解除静音，保证用户拖动后立即听到对应音量。
    @objc private func changeVolume() {
        guard let player, let slider = volumeSlider else { return }
        player.volume = Float(slider.doubleValue)
        player.isMuted = false
        updateControls()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        showsFullScreenToggleButton = false
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureControls(compatibility: usesCompatibilityControls)
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window?.firstResponder !== self {
                self.window?.makeFirstResponder(self)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let configuredSeekStep = PlaybackSettings.seekStepSeconds
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            toggleFullscreen()
        case 123: // Left arrow
            onCommand?(.seek(-abs(configuredSeekStep)))
        case 124: // Right arrow
            onCommand?(.seek(abs(configuredSeekStep)))
        case 126: // Up arrow
            player?.isMuted = false
            onCommand?(.adjustVolume(0.05))
            updateControls()
        case 125: // Down arrow
            player?.isMuted = false
            onCommand?(.adjustVolume(-0.05))
            updateControls()
        case 53: // Escape
            if onFullscreenExit != nil || fullscreenController != nil {
                toggleFullscreen()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// 全屏只创建新的显示视图，复用 AVPlayer，不搬动 SwiftUI 管理的原视图。
    @objc func toggleFullscreen() {
        if let onFullscreenExit { onFullscreenExit(); return }
        if fullscreenController != nil { closeFullscreen(); return }
        guard let player, let screen = window?.screen ?? NSScreen.main else { return }
        let controller = FullscreenPlayerController(player: player, screen: screen, onCommand: onCommand,
                                                    usesCompatibilityControls: usesCompatibilityControls,
                                                    sourceDuration: sourceDuration, timelineOffset: timelineOffset, preparationMessage: preparationMessage)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.player = controller.playerView.player
            controller.playerView.player = nil
            self.fullscreenController = nil
            self.updateControls()
            self.window?.makeFirstResponder(self)
        }
        fullscreenController = controller
        // 同一个播放器只挂到一个 AVPlayerView 上，避免多个输出层争夺画面。
        self.player = nil
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.playerView)
        controller.window?.toggleFullScreen(nil)
    }

    /// SwiftUI 更新播放对象和时间轴时同步全屏视图，继续复用同一播放器。
    func synchronizeFullscreen() {
        guard let fullscreenController else { return }
        if let player { fullscreenController.playerView.player = player; self.player = nil }
        fullscreenController.playerView.onCommand = onCommand
        fullscreenController.playerView.sourceDuration = sourceDuration
        fullscreenController.playerView.timelineOffset = timelineOffset
        fullscreenController.playerView.preparationMessage = preparationMessage
        fullscreenController.playerView.configureControls(compatibility: usesCompatibilityControls)
    }

    /// 退出页面或销毁代表视图时立即释放全屏窗口。
    func closeFullscreen() { fullscreenController?.close() }
}

/// 独立 AppKit 窗口用四边约束布局，窗口尺寸变化时视频始终居中铺满黑色背景。
final class FullscreenPlayerController: NSWindowController, NSWindowDelegate {
    let playerView = KeyboardPlayerView()
    var onClose: (() -> Void)?

    init(player: AVPlayer, screen: NSScreen, onCommand: ((PlaybackCommand) -> Void)?, usesCompatibilityControls: Bool = false,
         sourceDuration: Double? = nil, timelineOffset: Double = 0, preparationMessage: String? = nil) {
        let window = NSWindow(contentRect: screen.visibleFrame,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = container
        playerView.player = player
        playerView.sourceDuration = sourceDuration
        playerView.timelineOffset = timelineOffset
        playerView.preparationMessage = preparationMessage
        playerView.configureControls(compatibility: usesCompatibilityControls)
        playerView.videoGravity = .resizeAspect
        playerView.onCommand = onCommand
        playerView.onFullscreenExit = { [weak self] in
            guard let self, let window = self.window else { return }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            else { self.close() }
        }
        playerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 系统全屏退出动画完成后回到原播放页。
    func windowDidExitFullScreen(_ notification: Notification) { close() }

    /// 系统无法进入全屏时也回收窗口，并恢复内嵌播放器。
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { close() }

    /// 点击关闭按钮、Esc 和视图销毁共用同一清理路径。
    func windowWillClose(_ notification: Notification) {
        let completion = onClose
        onClose = nil
        completion?()
        playerView.player = nil
    }
}

/// 作为第三方网页线路的内嵌播放页容器。
struct NativeWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard nsView.url != url else { return }
        nsView.load(URLRequest(url: url))
    }
}
