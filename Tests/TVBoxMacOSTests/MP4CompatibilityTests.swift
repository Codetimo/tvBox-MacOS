import XCTest
import AVFoundation
@testable import TVBoxMacOS

final class MP4CompatibilityTests: XCTestCase {
    /// 真实 box 层级中区分 hev1、hvc1、avc1，并忽略 mdat/品牌中的同名文本。
    @MainActor
    func testSampleEntryDetectionAndMovieDuration() async throws {
        for codec in ["hev1", "hvc1", "avc1"] {
            let value = try await inspect(fixture(codec: codec))
            XCTAssertEqual(value?.retagHEVC, codec == "hev1" ? true : nil)
            if codec == "hev1" { XCTAssertEqual(value?.duration, 7_200) }
        }
        let unrelated = box("ftyp", Data("hev1".utf8)) + box("mdat", Data("hev1".utf8))
        let result = try await inspect(unrelated)
        XCTAssertNil(result)
    }

    /// 跳过大 mdat 到文件尾的 moov；支持扩展 box 长度和 mvhd v1。
    @MainActor
    func testTailMoovAnd64BitDuration() async throws {
        let movie = fixture(codec: "hev1", version: 1, tail: true)
        let value = try await inspect(movie)
        XCTAssertEqual(value?.retagHEVC, true)
        XCTAssertEqual(value?.duration, 7_200)
    }

    /// 大型 sample table 不应耗尽远端探测预算，备用视频轨不能覆盖 0:v:0 的 codec。
    @MainActor
    func testLargeSampleTablesAndSecondaryVideoAreSkipped() async throws {
        let large = try await inspect(fixture(codec: "hev1", largeTables: true))
        XCTAssertEqual(large?.retagHEVC, true)
        let ordinaryFirst = try await inspect(fixture(codec: "avc1", secondaryCodec: "hev1"))
        XCTAssertNil(ordinaryFirst)
    }

    /// 非法长度、截断和过多 box 不得触发错误的转封装，也不能无限探测。
    @MainActor
    func testMalformedAndTruncatedBoxesDoNotTriggerRemux() async throws {
        let valid = fixture(codec: "hev1")
        for data in [Data(valid.dropLast()), box("ftyp", Data()) + be(UInt64.max, 8),
                     box("ftyp", Data()) + be(1, 4) + Data("moov".utf8) + be(UInt64.max, 8),
                     box("ftyp", Data()) + (0..<300).reduce(Data()) { result, _ in result + box("free", Data()) }] {
            let result = try await inspect(data)
            XCTAssertNil(result)
        }
    }

    /// 用本地 Range 服务调用生产探测流程，不依赖外部站点和文件后缀。
    @MainActor
    private func inspect(_ data: Data) async throws -> MediaRemuxSession.Compatibility? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try data.write(to: folder.appendingPathComponent("init.mp4"))
        let server = LocalMediaHTTPServer(directory: folder)
        let base = try await server.start()
        defer { server.stop() }
        let channel = TVChannel(id: "mp4", name: "MP4 fixture", group: "test", logoURL: nil,
                                streamURL: base.appendingPathComponent("init.mp4"), headers: [:])
        return try await MediaRemuxSession.compatibility(channel)
    }

    /// 最小结构用于检验元数据解析，视频解码另由真实 FFmpeg fixture 覆盖。
    private func fixture(codec: String, version: UInt8 = 0, tail: Bool = false, largeTables: Bool = false, secondaryCodec: String? = nil) -> Data {
        var mvhd = Data([version, 0, 0, 0])
        mvhd += Data(repeating: 0, count: version == 1 ? 16 : 8)
        mvhd += be(1_000, 4) + be(7_200_000, version == 1 ? 8 : 4)
        let entry = box(codec, Data(repeating: 0, count: 78))
        let stsd = box("stsd", Data(repeating: 0, count: 4) + be(1, 4) + entry)
        let tables = largeTables ? (0..<10).reduce(Data()) { result, _ in result + box("stsz", Data(repeating: 0, count: 70_000)) } : Data()
        let trak = box("trak", box("mdia", box("minf", box("stbl", stsd + tables))))
        var contents = box("mvhd", mvhd) + trak
        if let secondaryCodec {
            let secondary = box("stsd", Data(repeating: 0, count: 4) + be(1, 4) + box(secondaryCodec, Data(repeating: 0, count: 78)))
            contents += box("trak", box("mdia", box("minf", box("stbl", secondary))))
        }
        let moov = tail ? be(1, 4) + Data("moov".utf8) + be(UInt64(contents.count + 16), 8) + contents : box("moov", contents)
        return box("ftyp", Data("isom0000".utf8)) + (tail ? box("mdat", Data(repeating: 0, count: 160_000)) : Data()) + moov
    }

    /// 写入标准 32 位 box 头。
    private func box(_ type: String, _ payload: Data) -> Data {
        be(UInt64(payload.count + 8), 4) + Data(type.utf8) + payload
    }

    /// 写入不依赖机器字节序的大端整数。
    private func be(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    /// 真实 hev1 文件经生产 HLS 管线后，必须保留总时长、可跳转且由 AVFoundation 解码。
    @MainActor
    func testHEV1RemuxSeekAndNativeDecode() async throws {
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TVBoxMacOS/runtime/media/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Run scripts/setup_media_runtime.sh for media integration tests") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let generator = Process()
        generator.executableURL = executable
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=24", "-t", "8",
                               "-c:v", "libx265", "-x265-params", "pools=1:frame-threads=1:log-level=error:keyint=24:bframes=0",
                               "-tag:v", "hev1", folder.appendingPathComponent("init.mp4").path]
        generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let server = LocalMediaHTTPServer(directory: folder)
        let base = try await server.start()
        defer { server.stop() }
        let channel = TVChannel(id: "hev1", name: "HEV1 fixture", group: "test", logoURL: nil,
                                streamURL: base.appendingPathComponent("init.mp4"), headers: [:])
        let detected = try await MediaRemuxSession.compatibility(channel)
        let compatibility = try XCTUnwrap(detected)
        XCTAssertTrue(compatibility.retagHEVC)
        XCTAssertEqual(try XCTUnwrap(compatibility.duration), 8, accuracy: 0.1)
        let session = try await MediaRemuxSession.start(channel: channel, startTime: 4, compatibility: compatibility)
        defer { session.stop() }
        XCTAssertEqual(session.startTime, 4)
        XCTAssertEqual(try XCTUnwrap(session.sourceDuration), 8, accuracy: 0.1)
        let (playlist, _) = try await URLSession.shared.data(from: session.playbackURL)
        let mediaBase = session.playbackURL.deletingLastPathComponent()
        var (movie, _) = try await URLSession.shared.data(from: mediaBase.appendingPathComponent("init.mp4"))
        for name in String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines).filter({ $0.hasSuffix(".m4s") }) {
            let (fragment, _) = try await URLSession.shared.data(from: mediaBase.appendingPathComponent(name))
            movie.append(fragment)
        }
        let output = folder.appendingPathComponent("decoded.mp4")
        try movie.write(to: output)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), 0x68766331)
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.start.seconds, 0, accuracy: 0.1)
        // 原片偏移单独保留；播放媒体的 empty edit 已统一归零，实际片段仍只有 4 秒。
        XCTAssertEqual(session.timelineOffset, 4, accuracy: 0.1)
        XCTAssertEqual(session.initialSeekTime, 0, accuracy: 0.1)
        XCTAssertEqual(range.duration.seconds, 4, accuracy: 0.2)
        let segmentDuration = String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines)
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).split(separator: ",")[0]) }.reduce(0, +)
        XCTAssertEqual(segmentDuration, 4, accuracy: 0.2)
        let decoder = AVAssetImageGenerator(asset: asset)
        decoder.requestedTimeToleranceBefore = .zero
        decoder.requestedTimeToleranceAfter = .zero
        var actualTime = CMTime.invalid
        let frame = try decoder.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: &actualTime)
        XCTAssertEqual(actualTime.seconds, 1, accuracy: 0.1)
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 180)
        // 同时验证 AVPlayer 对 HLS 使用局部时间：局部 1 秒对应原片 5 秒。
        let player = AVPlayer(url: session.playbackURL)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let deadline = Date().addingTimeInterval(10)
        while player.currentItem?.status == .unknown, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        player.currentItem?.add(videoOutput)
        var seekFinished: Bool?
        player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in seekFinished = finished }
        }
        let seekDeadline = Date().addingTimeInterval(10)
        while seekFinished == nil, Date() < seekDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        player.currentItem?.cancelPendingSeeks()
        XCTAssertEqual(seekFinished, true)
        player.pause()
        XCTAssertEqual(player.currentTime().seconds + session.timelineOffset, 5, accuracy: 0.3)
        XCTAssertNotNil(videoOutput.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil))
        player.play()
        let playbackDeadline = Date().addingTimeInterval(5)
        while player.currentTime().seconds < 1.25, Date() < playbackDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        player.pause()
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 1.25)
    }
}
