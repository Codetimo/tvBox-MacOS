import Foundation

/// 沿 ISO BMFF box 层级读取视频 sample entry；跳过 mdat，不扫描视频负载中的四字符标记。
@MainActor
final class MP4CompatibilityProbe {
    struct Metadata {
        var videoCodec: String?
        var requiresHEVCRetag: Bool { videoCodec == "hev1" }
        var duration: Double?
    }

    private let channel: TVChannel
    private let session: URLSession
    private var cache: Data
    private var cacheOffset: Int64 = 0
    private var fileLength: Int64?
    private var requests = 1
    private var boxes = 0
    private let deadline = Date().addingTimeInterval(20)
    private var metadata = Metadata()

    /// 复用第一次容器探测的字节和响应总长，不重复读取文件头。
    init(channel: TVChannel, prefix: Data, response: HTTPURLResponse, session: URLSession) {
        self.channel = channel
        self.session = session
        cache = prefix
        if let total = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last,
           let length = Int64(total), length > 0 { fileLength = length }
        else if response.statusCode == 200, response.expectedContentLength > 0 { fileLength = response.expectedContentLength }
    }

    /// 限定请求数、box 数和时间；支持 moov 在文件尾部以及 64 位大文件 box。
    func inspect() async throws -> Metadata {
        guard cache.count >= 8,
              ["ftyp", "moov", "free", "wide"].contains(String(decoding: cache[4..<8], as: UTF8.self)) else { return metadata }
        try await walk(start: 0, end: fileLength ?? Int64.max, path: [])
        return metadata
    }

    /// 每次最多读取 64 KiB，最多 8 次；同一元数据块内的子 box 复用缓存。
    private func read(at offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count > 0, count <= 65_536, offset <= Int64.max - Int64(count), Date() < deadline else {
            throw URLError(.cannotParseResponse)
        }
        let relative = offset - cacheOffset
        if relative >= 0, relative <= Int64(cache.count), Int64(count) <= Int64(cache.count) - relative {
            return cache.subdata(in: Int(relative)..<(Int(relative) + count))
        }
        guard requests < 8 else { throw URLError(.dataLengthExceedsMaximum) }
        requests += 1
        let fetched = try await MediaProbe.readPrefix(url: channel.streamURL, headers: channel.headers,
                                                      count: 65_536, offset: offset, session: session)
        cache = fetched.0
        cacheOffset = offset
        guard cache.count >= count else { throw URLError(.cannotParseResponse) }
        return Data(cache.prefix(count))
    }

    /// 只进入 moov/trak/mdia/minf/stbl/stsd，其他 box 直接按声明长度跳过。
    private func walk(start: Int64, end: Int64, path: [String]) async throws {
        var offset = start
        while offset < end {
            try Task.checkCancellation()
            guard boxes < 256, end - offset >= 8 else { throw URLError(.cannotParseResponse) }
            boxes += 1
            let header = try await read(at: offset, count: 8)
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var size = integer(header, at: 0, count: 4)
            var headerSize: Int64 = 8
            if size == 1 {
                size = integer(try await read(at: offset + 8, count: 8), at: 0, count: 8)
                headerSize = 16
            } else if size == 0 {
                guard end != Int64.max else { throw URLError(.cannotParseResponse) }
                size = UInt64(end - offset)
            }
            guard size >= UInt64(headerSize), size <= UInt64(end - offset) else { throw URLError(.cannotParseResponse) }
            let boxEnd = offset + Int64(size)
            let payload = offset + headerSize
            let expected = ["moov", "trak", "mdia", "minf", "stbl", "stsd"]
            if path.count < expected.count, type == expected[path.count], !(type == "trak" && metadata.videoCodec != nil) {
                if type == "stsd" {
                    guard boxEnd - payload >= 8 else { throw URLError(.cannotParseResponse) }
                    let fullHeader = try await read(at: payload, count: 8)
                    let entries = integer(fullHeader, at: 4, count: 4)
                    guard entries <= 32 else { throw URLError(.cannotParseResponse) }
                    try await readSampleEntries(start: payload + 8, end: boxEnd, count: Int(entries))
                } else {
                    try await walk(start: payload, end: boxEnd, path: path + [type])
                }
                // moov 后无需继续请求媒体数据，也避免未知文件总长时探测 EOF。
                // stsd 之后是可达数 MiB 的 sample table；所需字段已读完，跳过同级表项。
                if path.isEmpty || path.count >= 2 { return }
            } else if path == ["moov"], type == "mvhd" {
                try await readDuration(start: payload, end: boxEnd)
            }
            offset = boxEnd
        }
    }

    /// stsd 中的 hev1 才触发重封装；hvc1/avc1、品牌列表或 mdat 内同名文本均不触发。
    private func readSampleEntries(start: Int64, end: Int64, count: Int) async throws {
        var offset = start
        for _ in 0..<count {
            guard end - offset >= 8 else { throw URLError(.cannotParseResponse) }
            let entry = try await read(at: offset, count: 8)
            let size = integer(entry, at: 0, count: 4)
            guard size >= 8, size <= UInt64(end - offset) else { throw URLError(.cannotParseResponse) }
            let codec = String(decoding: entry[4..<8], as: UTF8.self)
            if ["hev1", "hvc1", "avc1", "avc3", "av01", "vp09", "vp08", "mp4v", "encv", "dvhe", "dvh1"].contains(codec) {
                // 与 FFmpeg 的 0:v:0 一致，只依据第一条视频轨；不受备用视频轨的 codec 影响。
                guard size >= 86 else { throw URLError(.cannotParseResponse) }
                if metadata.videoCodec == nil { metadata.videoCodec = codec }
            }
            offset += Int64(size)
        }
    }

    /// mvhd v0/v1 的 timescale 与 duration 用于兼容播放的原片进度，未知时长保留 nil。
    private func readDuration(start: Int64, end: Int64) async throws {
        guard end > start else { throw URLError(.cannotParseResponse) }
        let version = try await read(at: start, count: 1)[0]
        guard version <= 1 else { return }
        let count = version == 1 ? 32 : 20
        guard end - start >= count else { throw URLError(.cannotParseResponse) }
        let data = try await read(at: start, count: count)
        let scale = integer(data, at: version == 1 ? 20 : 12, count: 4)
        let duration = integer(data, at: version == 1 ? 24 : 16, count: version == 1 ? 8 : 4)
        guard scale > 0, duration > 0, duration != (version == 1 ? UInt64.max : UInt64(UInt32.max)) else { return }
        metadata.duration = Double(duration) / Double(scale)
    }

    /// 按大端读取已验证边界内的整数，避免非对齐内存访问。
    private func integer(_ data: Data, at offset: Int, count: Int) -> UInt64 {
        data[offset..<(offset + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
