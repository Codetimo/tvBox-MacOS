import XCTest
@testable import TVBoxMacOS

final class SourceLibraryRepositoryTests: XCTestCase {
    /// 并行提交的源库更新逐个执行完整读改写，不能互相覆盖。
    func testConcurrentImportsPreserveEverySource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = SourceLibraryRepository(fileURL: folder.appendingPathComponent("library.json"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let source = TVSource(name: "source-\(index)", location: URL(string: "https://example.com/\(index)")!, kind: .m3u)
                    let snapshot = SourceSnapshot(source: source, channels: [], fetchedAt: .now, parserVersion: "test", warnings: [])
                    _ = try await repository.upsert(snapshot: snapshot)
                }
            }
            try await group.waitForAll()
        }
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.sources.count, 12)
    }

    /// 异步修复完成之前源已被删除时，事务内再次校验，防止后台结果将其重新添加。
    func testLateRepairDoesNotRestoreDeletedSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = SourceLibraryRepository(fileURL: folder.appendingPathComponent("library.json"))
        let source = TVSource(name: "source", location: URL(string: "https://example.com/live")!, kind: .m3u)
        let snapshot = SourceSnapshot(source: source, channels: [], fetchedAt: .now, parserVersion: "test", warnings: [])
        let library = try await repository.upsert(snapshot: snapshot)
        let original = try XCTUnwrap(library.sources.first)
        _ = try await repository.remove(sourceID: original.id)
        let repaired = try await repository.replace(snapshot: snapshot, ifUnchanged: original)
        XCTAssertTrue(repaired.sources.isEmpty)
    }

    /// 文件系统访问失败不能被转换成 JSON 损坏，诊断需要保留原始错误类型。
    func testReadFailurePreservesFilesystemError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = SourceLibraryRepository(fileURL: folder)
        do { _ = try await repository.load(); XCTFail("目录不能读取为源库 JSON") }
        catch { XCTAssertFalse(error is SourceStoreError) }
    }
}
