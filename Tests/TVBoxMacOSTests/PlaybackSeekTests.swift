import XCTest
import AVKit
@testable import TVBoxMacOS

final class PlaybackSeekTests: XCTestCase {
    /// 未缓存跳转必须保留原片总长、播放器身份、音量和用户暂停状态。
    @MainActor
    func testUncachedSeekPreservesTimelinePlayerVolumeAndPause() async throws {
        let fixture = try await makeFixture()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.folder) }
        let coordinator = PlaybackCoordinator()
        defer { coordinator.stop() }
        coordinator.play(fixture.channel)
        try await waitUntil { coordinator.player?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(coordinator.player)
        let originalItem = try XCTUnwrap(player.currentItem)
        player.pause()
        player.volume = 0.35
        player.isMuted = true
        XCTAssertEqual(try XCTUnwrap(coordinator.sourceDuration), 96, accuracy: 0.2)

        coordinator.seek(to: 60)
        try await waitUntil {
            coordinator.timelineOffset == 60 && player.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(coordinator.player === player)
        XCTAssertFalse(player.currentItem === originalItem)
        XCTAssertEqual(try XCTUnwrap(coordinator.sourceDuration), 96, accuracy: 0.2)
        XCTAssertEqual(coordinator.timelineOffset, 60)
        XCTAssertEqual(player.volume, 0.35, accuracy: 0.001)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(coordinator.preparationMessage)
        XCTAssertNil(coordinator.errorMessage)
    }

    /// 连续请求两个未缓存位置时，只有最后一次请求能替换项目。
    @MainActor
    func testRapidUncachedSeeksUseLastTarget() async throws {
        let fixture = try await makeFixture()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.folder) }
        let coordinator = PlaybackCoordinator()
        defer { coordinator.stop() }
        coordinator.play(fixture.channel)
        try await waitUntil { coordinator.player?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(coordinator.player)
        player.pause()
        coordinator.seek(to: 60)
        coordinator.seek(to: 40)
        try await waitUntil {
            coordinator.timelineOffset == 40 && player.currentItem?.status == .readyToPlay
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(coordinator.timelineOffset, 40)
        XCTAssertTrue(coordinator.player === player)
        XCTAssertNil(coordinator.errorMessage)
    }

    /// 后台跳转尚未完成时，相对快进以待完成目标为基准累计。
    @MainActor
    func testRapidRelativeSeeksAccumulatePendingTarget() async throws {
        let fixture = try await makeFixture()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.folder) }
        let coordinator = PlaybackCoordinator()
        defer { coordinator.stop() }
        coordinator.play(fixture.channel)
        try await waitUntil { coordinator.player?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(coordinator.player)
        player.pause()
        coordinator.seek(to: 40)
        coordinator.seek(by: 10)
        try await waitUntil {
            coordinator.timelineOffset == 50 && player.currentItem?.status == .readyToPlay
        }
        XCTAssertEqual(coordinator.timelineOffset, 50)
        XCTAssertTrue(coordinator.player === player)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(coordinator.preparationMessage)
        XCTAssertNil(coordinator.errorMessage)
    }

    /// 从未缓存目标立即拖回已缓存区间时，必须取消前一次后台跳转。
    @MainActor
    func testCachedSeekCancelsPendingUncachedSeek() async throws {
        let fixture = try await makeFixture()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.folder) }
        let coordinator = PlaybackCoordinator()
        defer { coordinator.stop() }
        coordinator.play(fixture.channel)
        try await waitUntil {
            guard let item = coordinator.player?.currentItem, item.status == .readyToPlay else { return false }
            return item.seekableTimeRanges.contains {
                let range = $0.timeRangeValue
                return range.start.seconds <= 1 && CMTimeRangeGetEnd(range).seconds >= 1
            }
        }
        let player = try XCTUnwrap(coordinator.player)
        let item = try XCTUnwrap(player.currentItem)
        player.pause()
        coordinator.seek(to: 60)
        coordinator.seek(to: 1)
        XCTAssertNil(coordinator.preparationMessage)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(coordinator.timelineOffset, 0)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertNil(coordinator.errorMessage)
    }

    /// 停止播放后，尚在准备的新会话不能恢复播放器或遗留加载状态。
    @MainActor
    func testStopCancelsPendingUncachedSeek() async throws {
        let fixture = try await makeFixture()
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.folder) }
        let coordinator = PlaybackCoordinator()
        coordinator.play(fixture.channel)
        defer { coordinator.stop() }
        try await waitUntil { coordinator.player?.currentItem?.status == .readyToPlay }
        coordinator.seek(to: 60)
        coordinator.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(coordinator.player)
        XCTAssertNil(coordinator.sourceDuration)
        XCTAssertNil(coordinator.preparationMessage)
        XCTAssertNil(coordinator.compatibilityNotice)
        XCTAssertEqual(coordinator.timelineOffset, 0)
    }

    /// 长 GOP + B 帧 + AAC 在非关键帧目标也要落到准确原片位置，不能把前关键帧冒充目标。
    @MainActor
    func testNonKeyframeSeekWithAudioUsesOriginalTimeline() async throws {
        let fixture = try await makeFixture(withAudio: true)
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.folder) }
        let coordinator = PlaybackCoordinator()
        defer { coordinator.stop() }
        coordinator.play(fixture.channel)
        try await waitUntil { coordinator.player?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(coordinator.player)
        player.pause()
        coordinator.seek(to: 63.3)
        try await waitUntil {
            coordinator.timelineOffset > 59 && player.currentItem?.status == .readyToPlay &&
                abs(player.currentTime().seconds + coordinator.timelineOffset - 63.3) < 0.1
        }
        // 12 fps/B 帧 fixture 的最早音频 PTS 位于视频关键帧之前，两个轨道必须统一减该偏移。
        XCTAssertEqual(coordinator.timelineOffset, 59.839, accuracy: 0.03)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        player.currentItem?.add(output)
        try await waitUntil { output.hasNewPixelBuffer(forItemTime: player.currentTime()) }
        XCTAssertNotNil(output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil))
        XCTAssertEqual(player.currentTime().seconds + coordinator.timelineOffset, 63.3, accuracy: 0.1)
        XCTAssertEqual(player.rate, 0)
        coordinator.seek(to: 65.1)
        coordinator.seek(by: 1.2)
        try await waitUntil { abs(player.currentTime().seconds + coordinator.timelineOffset - 66.3) < 0.1 }
        XCTAssertNil(coordinator.errorMessage)
    }

    /// 生成长于初始缓存窗口的本地 MKV，以真实 HTTP Range 和 FFmpeg 验证跨缓存跳转。
    @MainActor
    private func makeFixture(withAudio: Bool = false) async throws -> (folder: URL, server: LocalMediaHTTPServer, channel: TVChannel) {
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TVBoxMacOS/runtime/media/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Run scripts/setup_media_runtime.sh for media integration tests")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("playback-seek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = LocalMediaHTTPServer(directory: folder)
        do {
            let generator = Process()
            generator.executableURL = executable
            let audioInput = withAudio ? ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"] : []
            generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                "testsrc2=s=160x90:r=12"] + audioInput + ["-t", "96", "-c:v", "libx264", "-preset", "ultrafast",
                "-g", withAudio ? "120" : "12", "-sc_threshold", "0", "-bf", withAudio ? "3" : "0",
                "-c:a", "aac", "-f", "matroska", folder.appendingPathComponent("init.mp4").path]
            generator.standardError = FileHandle.nullDevice
            try generator.run()
            generator.waitUntilExit()
            guard generator.terminationStatus == 0 else {
                throw NSError(domain: "PlaybackSeekTests.Fixture", code: Int(generator.terminationStatus))
            }
            let base = try await server.start()
            let channel = TVChannel(id: "seek-fixture", name: "Seek MKV", group: "test", logoURL: nil,
                                    streamURL: base.appendingPathComponent("init.mp4"), headers: [:])
            return (folder, server, channel)
        } catch {
            server.stop()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// 有界等待播放器异步状态，避免依赖本机解码或网络调度的固定延迟。
    @MainActor
    private func waitUntil(timeout: TimeInterval = 25, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw NSError(domain: "PlaybackSeekTests.Timeout", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for local playback state"])
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
