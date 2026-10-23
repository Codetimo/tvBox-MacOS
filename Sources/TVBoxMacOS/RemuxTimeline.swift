import Foundation

/// 读取 FFmpeg 保留源时间戳后写入的视频空 edit；它表示首关键帧在原片中的位置。
enum RemuxTimeline {
    /// 只检查 init.mp4 元数据，并严格验证 box 边界；不扫描媒体负载中的标记。
    static func videoStart(in data: Data) -> Double? {
        guard let root = boxes(data), let movie = root.first(where: { $0.type == "moov" }),
              let children = boxes(movie.data), let header = children.first(where: { $0.type == "mvhd" }),
              let version = header.data.first, version <= 1,
              let scale = integer(header.data, at: version == 1 ? 20 : 12, count: 4), scale > 0 else { return nil }
        for track in children where track.type == "trak" {
            guard let trackBoxes = boxes(track.data), let media = trackBoxes.first(where: { $0.type == "mdia" }),
                  let mediaBoxes = boxes(media.data), let handler = mediaBoxes.first(where: { $0.type == "hdlr" }),
                  handler.data.count >= 12,
                  String(decoding: handler.data[8..<12], as: UTF8.self) == "vide" else { continue }
            guard let edits = trackBoxes.first(where: { $0.type == "edts" }), let editBoxes = boxes(edits.data),
                  let list = editBoxes.first(where: { $0.type == "elst" }), let editVersion = list.data.first,
                  editVersion <= 1, let count = integer(list.data, at: 4, count: 4), count > 0, count <= 32 else { return nil }
            let width = editVersion == 1 ? 8 : 4
            let stride = width * 2 + 4
            guard list.data.count >= 8 + Int(count) * stride else { return nil }
            var delay: UInt64 = 0
            for index in 0..<Int(count) {
                let offset = 8 + index * stride
                guard let duration = integer(list.data, at: offset, count: width),
                      let mediaTime = integer(list.data, at: offset + width, count: width) else { return nil }
                if mediaTime != (width == 8 ? UInt64.max : UInt64(UInt32.max)) {
                    return Double(delay) / Double(scale)
                }
                let sum = delay.addingReportingOverflow(duration)
                guard !sum.overflow else { return nil }
                delay = sum.partialValue
            }
            return nil
        }
        return nil
    }

    /// 将所有媒体轨统一减去最早源起点，避免 AVPlayer 把源偏移当作片段前的空白。
    /// 只修改 empty edit 的时长，保留音视频之间原有的相对延迟。
    static func normalizedInitialization(_ data: Data) -> (data: Data, offset: Double)? {
        guard let root = boxes(data), let movie = root.first(where: { $0.type == "moov" }),
              let children = boxes(movie.data), let header = children.first(where: { $0.type == "mvhd" }),
              let version = header.data.first, version <= 1,
              let scale = integer(header.data, at: version == 1 ? 20 : 12, count: 4), scale > 0 else { return nil }
        var starts: [(offset: Int, width: Int, delay: UInt64)] = []
        for track in children where track.type == "trak" {
            guard let trackBoxes = boxes(track.data), let media = trackBoxes.first(where: { $0.type == "mdia" }),
                  let mediaBoxes = boxes(media.data), let handler = mediaBoxes.first(where: { $0.type == "hdlr" }),
                  handler.data.count >= 12,
                  ["vide", "soun"].contains(String(decoding: handler.data[8..<12], as: UTF8.self)) else { continue }
            guard let edits = trackBoxes.first(where: { $0.type == "edts" }) else {
                starts.append((0, 0, 0))
                continue
            }
            guard let editBoxes = boxes(edits.data), let list = editBoxes.first(where: { $0.type == "elst" }),
                  let editVersion = list.data.first, editVersion <= 1,
                  let count = integer(list.data, at: 4, count: 4), count == 1 || count == 2 else { return nil }
            let width = editVersion == 1 ? 8 : 4
            let stride = width * 2 + 4
            guard list.data.count >= 8 + Int(count) * stride,
                  let duration = integer(list.data, at: 8, count: width),
                  let mediaTime = integer(list.data, at: 8 + width, count: width) else { return nil }
            let emptyValue = width == 8 ? UInt64.max : UInt64(UInt32.max)
            let empty = mediaTime == emptyValue
            // FFmpeg 写一个媒体 edit，或一个 empty + 一个媒体 edit；其他布局拒绝猜测。
            guard (count == 1 && !empty) || (count == 2 && empty &&
                  integer(list.data, at: 8 + stride + width, count: width) != emptyValue) else { return nil }
            let position = movie.offset + track.offset + edits.offset + list.offset + 8
            starts.append((position, width, empty ? duration : 0))
        }
        guard let shift = starts.map(\.delay).min() else { return nil }
        var result = data
        if shift > 0 {
            for start in starts {
                let value = start.delay - shift
                for byte in 0..<start.width {
                    result[start.offset + byte] = UInt8(truncatingIfNeeded: value >> ((start.width - byte - 1) * 8))
                }
            }
        }
        return (result, Double(shift) / Double(scale))
    }

    /// init 元数据很小，最多允许 256 个直接子 box，支持普通、扩展和延伸到 EOF 的长度。
    private static func boxes(_ data: Data) -> [(type: String, data: Data, offset: Int)]? {
        var result: [(type: String, data: Data, offset: Int)] = []
        var offset = 0
        while offset < data.count {
            guard result.count < 256, let shortSize = integer(data, at: offset, count: 4), data.count - offset >= 8 else { return nil }
            let header = shortSize == 1 ? 16 : 8
            guard let size = shortSize == 1 ? integer(data, at: offset + 8, count: 8) : (shortSize == 0 ? UInt64(data.count - offset) : shortSize),
                  size >= header, size <= data.count - offset else { return nil }
            let end = offset + Int(size)
            result.append((String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self), data.subdata(in: (offset + header)..<end), offset + header))
            offset = end
        }
        return result
    }

    /// 使用大端逐字节解析，拒绝截断或越界读取。
    private static func integer(_ data: Data, at offset: Int, count: Int) -> UInt64? {
        guard offset >= 0, count > 0, count <= 8, offset <= data.count, count <= data.count - offset else { return nil }
        return data[offset..<(offset + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
