import XCTest
@testable import TVBoxMacOS

final class RemuxTimelineTests: XCTestCase {
    func testReadsVideoEmptyEditInBothVersions() {
        for version in [UInt8(0), 1] {
            XCTAssertEqual(RemuxTimeline.videoStart(in: fixture(version: version, delay: 10_021)), 10.021)
            XCTAssertEqual(RemuxTimeline.videoStart(in: fixture(version: version, delay: 0)), 0)
        }
    }

    func testNormalizesBothTracksWithoutChangingRelativeDelay() throws {
        for version in [UInt8(0), 1] {
            let source = fixture(version: version, delay: 10_021, audioDelay: 9_919)
            let normalized = try XCTUnwrap(RemuxTimeline.normalizedInitialization(source))
            XCTAssertEqual(normalized.offset, 9.919, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(RemuxTimeline.videoStart(in: normalized.data)), 0.102, accuracy: 0.001)
            let repeated = try XCTUnwrap(RemuxTimeline.normalizedInitialization(normalized.data))
            XCTAssertEqual(repeated.offset, 0)
            XCTAssertEqual(repeated.data, normalized.data)
            for count in 0..<source.count { XCTAssertNil(RemuxTimeline.normalizedInitialization(source.prefix(count))) }
        }
    }

    func testRejectsTruncationZeroScaleAndNonVideoTracks() {
        let data = fixture(version: 1, delay: 10_021)
        for size in 0..<data.count { XCTAssertNil(RemuxTimeline.videoStart(in: data.prefix(size))) }
        XCTAssertNil(RemuxTimeline.videoStart(in: fixture(version: 0, delay: 10, scale: 0)))
        XCTAssertNil(RemuxTimeline.videoStart(in: fixture(version: 0, delay: 10, mediaType: "soun")))
        XCTAssertNil(RemuxTimeline.videoStart(in: Data("elst vide mvhd".utf8)))
    }

    /// 仅构造读取所需的 box，覆盖 movie timescale 和 elst 的 32/64 位布局。
    private func fixture(version: UInt8, delay: UInt64, scale: UInt64 = 1000, mediaType: String = "vide", audioDelay: UInt64? = nil) -> Data {
        let width = version == 1 ? 8 : 4
        let header = Data([version, 0, 0, 0]) + Data(repeating: 0, count: width * 2) + number(scale, width: 4)
        let handler = Data(repeating: 0, count: 8) + Data(mediaType.utf8)
        let empty = number(delay, width: width) + Data(repeating: 255, count: width) + number(65_536, width: 4)
        let media = number(0, width: width) + number(0, width: width) + number(65_536, width: 4)
        let list = Data([version, 0, 0, 0]) + number(2, width: 4) + empty + media
        let track = box("mdia", box("hdlr", handler)) + box("edts", box("elst", list))
        var tracks = box("trak", track)
        if let audioDelay {
            let audioEmpty = number(audioDelay, width: width) + Data(repeating: 255, count: width) + number(65_536, width: 4)
            let audioList = Data([version, 0, 0, 0]) + number(2, width: 4) + audioEmpty + media
            let audioTrack = box("mdia", box("hdlr", Data(repeating: 0, count: 8) + Data("soun".utf8))) + box("edts", box("elst", audioList))
            tracks += box("trak", audioTrack)
        }
        return box("ftyp", Data()) + box("moov", box("mvhd", header) + tracks)
    }

    /// 编码大端整数，测试数据不依赖宿主机字节序。
    private func number(_ value: UInt64, width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    /// 包装标准长度 box，父子边界与真实 init.mp4 一致。
    private func box(_ type: String, _ payload: Data) -> Data {
        number(UInt64(payload.count + 8), width: 4) + Data(type.utf8) + payload
    }
}
