import XCTest
import AVFoundation
@testable import TVBoxMacOS

final class MediaCompatibilityTests: XCTestCase {
    func testDetectsMatroskaDespiteMP4Filename() {
        XCTAssertTrue(MediaRemuxSession.isMatroska([0x1a, 0x45, 0xdf, 0xa3, 0x42]))
        XCTAssertFalse(MediaRemuxSession.isMatroska([0, 0, 0, 32, 0x66, 0x74, 0x79, 0x70]))
        XCTAssertFalse(MediaRemuxSession.isMatroska([0x1a, 0x45]))
    }

    func testMatroskaDurationUsesScaleAndAcceptsUnknownSegmentSize() {
        let duration = ebmlElement([0x44, 0x89], payload: bigEndianBytes(Double(7_200).bitPattern, count: 8))
        let scale = ebmlElement([0x2a, 0xd7, 0xb1], payload: [0x0f, 0x42, 0x40])
        // Duration 可以出现在 TimestampScale 前面。
        XCTAssertEqual(MediaRemuxSession.matroskaDuration(in: matroskaFixture(info: duration + scale)), 7.2)
        let customScale = ebmlElement([0x2a, 0xd7, 0xb1], payload: [0x3b, 0x9a, 0xca, 0x00])
        let floatDuration = ebmlElement([0x44, 0x89], payload: bigEndianBytes(UInt64(Float(42.5).bitPattern), count: 4))
        XCTAssertEqual(MediaRemuxSession.matroskaDuration(in: matroskaFixture(info: customScale + floatDuration, unknownSegmentSize: true)), 42.5)
        XCTAssertEqual(MediaRemuxSession.matroskaDuration(in: matroskaFixture(info: duration)), 7.2)
    }

    func testMatroskaDurationRejectsTruncatedInvalidAndMisplacedMetadata() {
        let duration = ebmlElement([0x44, 0x89], payload: bigEndianBytes(Double(1_000).bitPattern, count: 8))
        let valid = matroskaFixture(info: duration)
        for length in 0..<valid.count {
            XCTAssertNil(MediaRemuxSession.matroskaDuration(in: valid.prefix(length)))
        }
        for value in [Double.nan, .infinity, -1, 0] {
            let invalid = ebmlElement([0x44, 0x89], payload: bigEndianBytes(value.bitPattern, count: 8))
            XCTAssertNil(MediaRemuxSession.matroskaDuration(in: matroskaFixture(info: invalid)))
        }
        let zeroScale = ebmlElement([0x2a, 0xd7, 0xb1], payload: [0])
        XCTAssertNil(MediaRemuxSession.matroskaDuration(in: matroskaFixture(info: duration + zeroScale)))
        XCTAssertNil(MediaRemuxSession.matroskaDuration(in: matroskaFixture(info: [0x44, 0x89, 0xff])))
        XCTAssertNil(MediaRemuxSession.matroskaDuration(in: matroskaFixture(info: [0x44, 0x89, 0x00])))
        let unrelatedPayload = ebmlElement([0xec], payload: ebmlElement([0x15, 0x49, 0xa9, 0x66], payload: duration))
        let wrongLevel = Data(ebmlElement([0x1a, 0x45, 0xdf, 0xa3], payload: []) + ebmlElement([0x18, 0x53, 0x80, 0x67], payload: unrelatedPayload))
        XCTAssertNil(MediaRemuxSession.matroskaDuration(in: wrongLevel))
    }

    /// 构造短 EBML 元素，测试不依赖真实提供商或文件扩展名。
    private func ebmlElement(_ identifier: [UInt8], payload: [UInt8]) -> [UInt8] {
        precondition(payload.count < 127)
        return identifier + [0x80 | UInt8(payload.count)] + payload
    }

    /// 构造确定或未知长度的 Segment，覆盖流式 Matroska 的两种封装。
    private func matroskaFixture(info: [UInt8], unknownSegmentSize: Bool = false) -> Data {
        let header = ebmlElement([0x1a, 0x45, 0xdf, 0xa3], payload: [])
        let segmentContents = ebmlElement([0x15, 0x49, 0xa9, 0x66], payload: info)
        let segment = unknownSegmentSize ? [0x18, 0x53, 0x80, 0x67, 0xff] + segmentContents : ebmlElement([0x18, 0x53, 0x80, 0x67], payload: segmentContents)
        return Data(header + segment)
    }

    /// EBML 浮点数采用大端字节序，避免测试依赖宿主机字节序。
    private func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    func testByteRangesAndInvalidInput() {
        XCTAssertEqual(LocalMediaHTTPServer.byteRange("bytes=0-1", length: 100), 0..<2)
        XCTAssertEqual(LocalMediaHTTPServer.byteRange("bytes=90-", length: 100), 90..<100)
        XCTAssertEqual(LocalMediaHTTPServer.byteRange("bytes=-10", length: 100), 90..<100)
        XCTAssertEqual(LocalMediaHTTPServer.byteRange("bytes=90-999", length: 100), 90..<100)
        for value in ["bytes=100-", "bytes=9-1", "bytes=0-1,2-3", "bytes=-0", "garbage"] {
            XCTAssertNil(LocalMediaHTTPServer.byteRange(value, length: 100))
        }
        XCTAssertNil(LocalMediaHTTPServer.byteRange("bytes=0-1", length: 0))
    }

    func testServerRejectsTraversalAndRequiresSessionPath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("0123456789".utf8).write(to: folder.appendingPathComponent("init.mp4"))
        let server = LocalMediaHTTPServer(directory: folder)
        let base = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: base.appendingPathComponent("init.mp4"))
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "2345")
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
        let wrong = base.deletingLastPathComponent().appendingPathComponent("init.mp4")
        let (_, forbidden) = try await URLSession.shared.data(from: wrong)
        XCTAssertEqual((forbidden as? HTTPURLResponse)?.statusCode, 404)
        for name in ["../init.mp4", "%2e%2e/secret", "file.txt", "segment-000001.m4s.tmp", "segment-000001.m4s/secret"] {
            XCTAssertFalse(LocalMediaHTTPServer.isAllowedFilename(name))
        }
        XCTAssertTrue(LocalMediaHTTPServer.isAllowedFilename("segment-000001.m4s"))
    }
    @MainActor
    func testH264MatroskaRemuxAndStop() async throws {
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TVBoxMacOS/runtime/media/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Run scripts/setup_media_runtime.sh for media integration tests") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("init.mp4")
        let generator = Process()
        generator.executableURL = executable
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=24", "-t", "2", "-c:v", "libx264", "-f", "matroska", fixture.path]
        generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let origin = LocalMediaHTTPServer(directory: folder)
        let base = try await origin.start()
        defer { origin.stop() }
        let channel = TVChannel(id: "fixture", name: "H264 MKV", group: "test", logoURL: nil, streamURL: base.appendingPathComponent("init.mp4"), headers: [:])
        let needsRemux = try await MediaRemuxSession.needsRemux(channel)
        XCTAssertTrue(needsRemux)
        let session = try await MediaRemuxSession.start(channel: channel)
        defer { session.stop() }
        XCTAssertEqual(try XCTUnwrap(session.sourceDuration), 2, accuracy: 0.1)
        XCTAssertEqual(session.startTime, 0)
        let (data, response) = try await URLSession.shared.data(from: session.playbackURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("#EXTINF:"))
        session.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            _ = try await URLSession.shared.data(for: URLRequest(url: session.playbackURL, timeoutInterval: 1))
            XCTFail("Stopped session must not keep serving media")
        } catch { XCTAssertTrue(error is URLError) }
    }

    @MainActor
    func testMatroskaSeekKeepsFullDurationAndResetsFragmentTimeline() async throws {
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TVBoxMacOS/runtime/media/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Run scripts/setup_media_runtime.sh for media integration tests") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let generator = Process()
        generator.executableURL = executable
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=24", "-t", "8", "-c:v", "libx264", "-g", "24", "-bf", "0", "-f", "matroska", folder.appendingPathComponent("init.mp4").path]
        generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let origin = LocalMediaHTTPServer(directory: folder)
        let base = try await origin.start()
        defer { origin.stop() }
        let channel = TVChannel(id: "seek-fixture", name: "Seek MKV", group: "test", logoURL: nil, streamURL: base.appendingPathComponent("init.mp4"), headers: [:])
        let session = try await MediaRemuxSession.start(channel: channel, startTime: 4)
        defer { session.stop() }
        XCTAssertEqual(try XCTUnwrap(session.sourceDuration), 8, accuracy: 0.1)
        XCTAssertEqual(session.startTime, 4)
        let (playlistData, _) = try await URLSession.shared.data(from: session.playbackURL)
        let playlist = String(decoding: playlistData, as: UTF8.self)
        let segmentNames = playlist.components(separatedBy: .newlines).filter { $0.hasSuffix(".m4s") }
        XCTAssertFalse(segmentNames.isEmpty)
        let mediaBase = session.playbackURL.deletingLastPathComponent()
        var (movie, _) = try await URLSession.shared.data(from: mediaBase.appendingPathComponent("init.mp4"))
        for name in segmentNames {
            let (fragment, _) = try await URLSession.shared.data(from: mediaBase.appendingPathComponent(name))
            movie.append(fragment)
        }
        let movieURL = folder.appendingPathComponent("seek-result.mp4")
        try movie.write(to: movieURL)
        let asset = AVURLAsset(url: movieURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.start.seconds, 0, accuracy: 0.1)
        XCTAssertEqual(range.duration.seconds, 4, accuracy: 0.1)
    }

}
