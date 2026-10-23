import XCTest
@testable import TVBoxMacOS

final class SourceIdentityMigrationTests: XCTestCase {
    func testLoadRepairsBrokenTemplateIDsAndPersistsStableResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(fileURL: directory.appendingPathComponent("source-library.json"))
        let source = TVSource(name: "已有源", location: URL(string: "https://source.example/config.json")!, kind: .tvboxJSON)
        let broken = "(source.id.uuidString)|(name)|(url.absoluteString)"
        let channels = [channel(broken, name: "新闻", path: "news"), channel(broken, name: "体育", path: "sport"),
                        channel("valid-favorite", name: "电影", path: "movie")]
        let snapshot = SourceSnapshot(source: source, channels: channels, fetchedAt: .now, parserVersion: "legacy", warnings: ["原警告"])
        try store.save(SourceLibrary(sources: [StoredSource(source: source, snapshot: snapshot)]))
        let migrated = try store.load()
        let repaired = try XCTUnwrap(migrated.sources.first?.snapshot)
        XCTAssertEqual(Set(repaired.channels.map(\.id)).count, 3)
        XCTAssertEqual(repaired.channels.last?.id, "valid-favorite")
        XCTAssertEqual(repaired.channels.map(\.streamURL), channels.map(\.streamURL))
        XCTAssertEqual(repaired.channels.map(\.headers), channels.map(\.headers))
        XCTAssertEqual(repaired.channels.map(\.name), channels.map(\.name))
        XCTAssertEqual(repaired.warnings, snapshot.warnings)
        XCTAssertEqual(repaired.parserVersion, snapshot.parserVersion)
        XCTAssertEqual(try store.load(), migrated)
    }

    func testDuplicateIDsAcrossSourcesAndGeneratedIDCollisionsStayUnique() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(fileURL: directory.appendingPathComponent("source-library.json"))
        let first = TVSource(name: "一", location: URL(string: "https://source.example/a.json")!, kind: .tvboxJSON)
        let second = TVSource(name: "二", location: URL(string: "https://source.example/b.json")!, kind: .tvboxJSON)
        let broken = channel("duplicate", name: "新闻", path: "news")
        let reserved = stableChannelID(source: first, name: broken.name, url: broken.streamURL)
        let valid = channel(reserved, name: "其他", path: "other")
        let snapshots = [(first, [broken, valid]), (second, [broken])].map { source, channels in
            StoredSource(source: source, snapshot: SourceSnapshot(source: source, channels: channels, fetchedAt: .now, parserVersion: "legacy", warnings: []))
        }
        try store.save(SourceLibrary(sources: snapshots))
        let migrated = try store.load()
        let all = migrated.sources.flatMap { $0.snapshot?.channels ?? [] }
        XCTAssertEqual(Set(all.map(\.id)).count, 3)
        XCTAssertEqual(all[1].id, reserved)
        XCTAssertEqual(all.map(\.streamURL), [broken.streamURL, valid.streamURL, broken.streamURL])
        XCTAssertEqual(try store.load(), migrated)
    }

    /// 构造保存过的真实频道字段，迁移只能改变有歧义的身份。
    private func channel(_ id: String, name: String, path: String) -> TVChannel {
        TVChannel(id: id, name: name, group: "直播", logoURL: nil,
                  streamURL: URL(string: "https://cdn.example/\(path).m3u8?token=PreserveCase")!, headers: ["User-Agent": "ExistingAgent"])
    }
}
