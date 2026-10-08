import XCTest
@testable import TVBoxMacOS

final class SourceAdapterTests: XCTestCase {
    func testM3UParsesChannelAndGroup() throws {
        let source = TVSource(name: "fixture", location: URL(string: "https://example.com/live.m3u")!, kind: .m3u)
        let data = Data("#EXTM3U\n#EXTINF:-1 tvg-name=\"News\" group-title=\"News\",News HD\nhttps://example.com/news.m3u8\n".utf8)
        let snapshot = try M3UAdapter().parse(data: data, source: source)
        XCTAssertEqual(snapshot.channels.count, 1)
        XCTAssertEqual(snapshot.channels[0].group, "News")
        XCTAssertEqual(snapshot.channels[0].name, "News HD")
    }
}
