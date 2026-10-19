import Foundation

/// 一个源及其最近一次成功加载的快照。
struct StoredSource: Codable, Hashable, Identifiable {
    var source: TVSource
    var snapshot: SourceSnapshot?

    var id: UUID { source.id }
}

/// 本地源库的持久化结构。保留顶层结构，便于后续增加版本字段而不影响现有数据。
struct SourceLibrary: Codable, Hashable {
    var sources: [StoredSource]
    var selectedSourceID: UUID?

    init(sources: [StoredSource] = [], selectedSourceID: UUID? = nil) {
        self.sources = sources
        self.selectedSourceID = selectedSourceID
    }
}

enum SourceStoreError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "本地源库数据损坏，无法读取。"
        }
    }
}

/// 负责保存源配置和快照。默认文件位于 macOS Application Support 目录。
final class SourceStore {
    let fileURL: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - fileURL: 可选的自定义文件路径，主要用于测试或便携部署。
    ///   - fileManager: 文件系统实现，默认使用系统 FileManager。
    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else if let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.fileURL = appSupport
                .appendingPathComponent("TVBoxMacOS", isDirectory: true)
                .appendingPathComponent("source-library.json")
        } else {
            // Application Support 不可用时仍允许应用运行，后续保存会返回具体文件错误。
            self.fileURL = fileManager.temporaryDirectory
                .appendingPathComponent("TVBoxMacOS", isDirectory: true)
                .appendingPathComponent("source-library.json")
        }
    }

    /// 读取本地源库；首次运行或文件尚不存在时返回空库。
    func load() throws -> SourceLibrary {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SourceLibrary()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder.tvBox.decode(SourceLibrary.self, from: data)
        } catch let error as SourceStoreError {
            throw error
        } catch {
            throw SourceStoreError.invalidData
        }
    }

    /// 以原子方式保存源库，避免应用中断时留下半个 JSON 文件。
    func save(_ library: SourceLibrary) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.tvBox.encode(library)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 添加或更新源，并保存其最新快照；同一地址会复用已有源 ID。
    @discardableResult
    func upsert(snapshot: SourceSnapshot) throws -> SourceLibrary {
        var library = try load()
        var snapshot = snapshot
        if let index = library.sources.firstIndex(where: {
            $0.source.location.absoluteString == snapshot.source.location.absoluteString
        }) {
            let existingID = library.sources[index].source.id
            snapshot.source = TVSource(
                id: existingID,
                name: snapshot.source.name,
                location: snapshot.source.location,
                kind: snapshot.source.kind,
                updatedAt: snapshot.source.updatedAt
            )
            library.sources[index] = StoredSource(source: snapshot.source, snapshot: snapshot)
        } else {
            library.sources.append(StoredSource(source: snapshot.source, snapshot: snapshot))
        }
        try save(library)
        return library
    }

    /// 删除指定源及其快照，并清理选中状态。
    @discardableResult
    func remove(sourceID: UUID) throws -> SourceLibrary {
        var library = try load()
        library.sources.removeAll { $0.id == sourceID }
        if library.selectedSourceID == sourceID {
            library.selectedSourceID = nil
        }
        try save(library)
        return library
    }
}

private extension JSONEncoder {
    static var tvBox: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var tvBox: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
