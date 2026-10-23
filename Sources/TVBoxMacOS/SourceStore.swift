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
            create: false
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
        let data = try Data(contentsOf: fileURL)
        let original: SourceLibrary
        do {
            original = try JSONDecoder.tvBox.decode(SourceLibrary.self, from: data)
        } catch {
            throw SourceStoreError.invalidData
        }
        let library = normalizedChannelIdentities(in: original)
        if library != original { try save(library) }
        return library
    }

    /// 旧版本曾将字符串插值模板保存为所有频道的 ID；仅修复坏值和冲突，保留正常收藏引用。
    private func normalizedChannelIdentities(in original: SourceLibrary) -> SourceLibrary {
        let channels = original.sources.flatMap { $0.snapshot?.channels ?? [] }
        let counts = Dictionary(grouping: channels, by: \.id).mapValues(\.count)
        let brokenTemplate = "(source.id.uuidString)|(name)|(url.absoluteString)"
        let needsRepair: (String) -> Bool = { id in
            id.isEmpty || id == brokenTemplate || (counts[id] ?? 0) > 1
        }
        guard channels.contains(where: { needsRepair($0.id) }) else { return original }
        // 正常唯一 ID 预先保留，避免新生成的身份抢占另一个频道的既有收藏。
        var used = Set(channels.filter { !needsRepair($0.id) }.map(\.id))
        var library = original
        for sourceIndex in library.sources.indices {
            guard var snapshot = library.sources[sourceIndex].snapshot else { continue }
            let source = library.sources[sourceIndex].source
            snapshot.channels = snapshot.channels.map { channel in
                guard needsRepair(channel.id) else { return channel }
                let base = stableChannelID(source: source, name: channel.name, url: channel.streamURL)
                var id = base
                var suffix = 1
                while !used.insert(id).inserted {
                    id = "\(base)|duplicate-\(suffix)"
                    suffix += 1
                }
                return TVChannel(id: id, name: channel.name, group: channel.group, logoURL: channel.logoURL,
                                 streamURL: channel.streamURL, headers: channel.headers)
            }
            library.sources[sourceIndex].snapshot = snapshot
        }
        return library
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
            let previousChannels = library.sources[index].snapshot?.channels ?? []
            let existingID = library.sources[index].source.id
            snapshot.source = TVSource(
                id: existingID,
                name: snapshot.source.name,
                location: snapshot.source.location,
                kind: snapshot.source.kind,
                updatedAt: snapshot.source.updatedAt
            )
            snapshot.channels = reconciledChannels(snapshot.channels, previous: previousChannels, source: snapshot.source)
            library.sources[index] = StoredSource(source: snapshot.source, snapshot: snapshot)
        } else {
            library.sources.append(StoredSource(source: snapshot.source, snapshot: snapshot))
        }
        try save(library)
        return library
    }

    private struct ChannelName: Hashable {
        let name: String
        let group: String

        /// 使用名称和分组共同匹配地址轮换的频道，不合并同名的不同分组。
        init(_ channel: TVChannel) {
            name = channel.name
            group = channel.group
        }
    }

    /// 保留旧收藏引用的频道 ID；优先按地址匹配，地址变化时只复用两侧均唯一的同名同组频道。
    private func reconciledChannels(_ channels: [TVChannel], previous: [TVChannel], source: TVSource) -> [TVChannel] {
        let byURL = Dictionary(grouping: previous) { channelURLIdentity($0.streamURL) }
        let byName = Dictionary(grouping: previous, by: ChannelName.init)
        let currentNames = Dictionary(grouping: channels, by: ChannelName.init)
        var usedIDs = Set<String>()
        // 地址匹配优先于名称回退，避免新频道先占用了稍后精确匹配所需的旧 ID。
        let exactMatches = channels.map { channel -> String? in
            let matches = byURL[channelURLIdentity(channel.streamURL)] ?? []
            return matches.count == 1 ? matches[0].id : nil
        }
        let reservedIDs = Set(exactMatches.compactMap { $0 })
        return channels.enumerated().map { index, channel in
            var preservedID = exactMatches[index]
            if preservedID == nil {
                let name = ChannelName(channel)
                if let matches = byName[name], matches.count == 1, currentNames[name]?.count == 1,
                   !reservedIDs.contains(matches[0].id) {
                    preservedID = matches[0].id
                }
            }
            let candidate = preservedID ?? stableChannelID(source: source, name: channel.name, url: channel.streamURL)
            let id = usedIDs.insert(candidate).inserted ? candidate : stableChannelID(source: source, name: channel.name, url: channel.streamURL)
            return TVChannel(id: id, name: channel.name, group: channel.group, logoURL: channel.logoURL,
                             streamURL: channel.streamURL, headers: channel.headers)
        }
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

/// 串行处理完整的读改写事务，使 UI 不在主线程执行文件 I/O，避免并发导入丢失更新。
actor SourceLibraryRepository {
    private let store: SourceStore

    /// 自定义文件路径用于测试；所有实际读取和写入都在 actor 隔离域执行。
    init(fileURL: URL? = nil) { store = SourceStore(fileURL: fileURL) }

    /// 异步调用方读取库，损坏内容与文件系统错误分别保留。
    func load() throws -> SourceLibrary { try store.load() }

    /// 一个不可交错的事务更新站源并返回最新库。
    func upsert(snapshot: SourceSnapshot) throws -> SourceLibrary { try store.upsert(snapshot: snapshot) }

    /// 删除源与清理选择状态属于同一个事务。
    func remove(sourceID: UUID) throws -> SourceLibrary { try store.remove(sourceID: sourceID) }

    /// 修复结果仅在原始快照仍有效时落盘，防止后台任务复活已删除的站源。
    func replace(snapshot: SourceSnapshot, ifUnchanged original: StoredSource) throws -> SourceLibrary {
        let current = try store.load()
        guard current.sources.first(where: { $0.id == original.id }) == original else { return current }
        return try store.upsert(snapshot: snapshot)
    }
}
