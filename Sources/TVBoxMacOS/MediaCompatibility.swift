import Foundation
import Network
import Darwin

/// 为 AVPlayer 不支持的 MKV 容器提供本地 HLS；视频只换容器，音频转换为 AAC。
@MainActor
final class MediaRemuxSession {
    let playbackURL: URL
    let sourceDuration: Double?
    let startTime: Double
    private let process: Process
    private let server: LocalMediaHTTPServer
    private let directory: URL

    private init(playbackURL: URL, sourceDuration: Double?, startTime: Double, process: Process, server: LocalMediaHTTPServer, directory: URL) {
        self.playbackURL = playbackURL
        self.sourceDuration = sourceDuration
        self.startTime = startTime
        self.process = process
        self.server = server
        self.directory = directory
    }

    deinit { Self.cleanup(process: process, server: server, directory: directory) }

    /// 检查真实文件头，不信任网盘文件名或错误的 Content-Type。
    static func needsRemux(_ channel: TVChannel) async throws -> Bool {
        let url = channel.streamURL
        let localProxy = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        guard localProxy || url.pathExtension.lowercased() == "mkv" else { return false }
        return isMatroska(Array(try await readPrefix(channel, count: 4)))
    }

    /// 用有界流读取文件头；即便源站忽略 Range，也只保留指定字节数。
    private static func readPrefix(_ channel: TVChannel, count: Int) async throws -> Data {
        var request = URLRequest(url: channel.streamURL, timeoutInterval: 15)
        playbackHTTPHeaders(overrides: channel.headers).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=0-\(count - 1)", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SourceParseError.invalidInput("媒体服务返回 HTTP \(status)，请重新解析或切换线路。")
        }
        var prefix = Data()
        for try await byte in bytes {
            prefix.append(byte)
            if prefix.count == count { break }
        }
        return prefix
    }

    /// EBML 文件头用于识别 Matroska，包括被错误命名为 MP4 的资源。
    nonisolated static func isMatroska(_ prefix: [UInt8]) -> Bool { prefix.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) }

    /// 仅沿 EBML 的 Segment/Info 层级读取时长，避免把视频负载里的相同字节误认为元数据。
    nonisolated static func matroskaDuration(in prefix: Data) -> Double? {
        let bytes = Array(prefix)
        guard isMatroska(bytes) else { return nil }
        var offset = 0
        while let element = ebmlElement(in: bytes, at: offset, limit: bytes.count) {
            if element.id == 0x18538067 {
                let segmentEnd = element.size.map { element.payload + Int(min($0, UInt64(bytes.count - element.payload))) } ?? bytes.count
                var childOffset = element.payload
                while let child = ebmlElement(in: bytes, at: childOffset, limit: segmentEnd) {
                    guard let size = child.size, size <= UInt64(segmentEnd - child.payload) else { return nil }
                    let childEnd = child.payload + Int(size)
                    if child.id == 0x1549a966 { return durationFromInfo(bytes, start: child.payload, end: childEnd) }
                    childOffset = childEnd
                }
                return nil
            }
            guard let size = element.size, size <= UInt64(bytes.count - element.payload) else { return nil }
            offset = element.payload + Int(size)
        }
        return nil
    }

    /// Duration 的单位由 TimestampScale 决定；两者允许任意顺序，缺少 scale 时使用规范默认值。
    nonisolated private static func durationFromInfo(_ bytes: [UInt8], start: Int, end: Int) -> Double? {
        var offset = start
        var scale: UInt64 = 1_000_000
        var duration: Double?
        while offset < end {
            guard let element = ebmlElement(in: bytes, at: offset, limit: end),
                  let size = element.size, size <= UInt64(end - element.payload) else { return nil }
            let elementEnd = element.payload + Int(size)
            if element.id == 0x2ad7b1 || element.id == 0x4489 {
                guard (1...8).contains(size) else { return nil }
                let value = bytes[element.payload..<elementEnd].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                if element.id == 0x2ad7b1 {
                    guard value > 0 else { return nil }
                    scale = value
                } else if size == 4 {
                    duration = Double(Float(bitPattern: UInt32(value)))
                } else if size == 8 {
                    duration = Double(bitPattern: value)
                } else { return nil }
            }
            offset = elementEnd
        }
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let seconds = duration * (Double(scale) / 1_000_000_000)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// 验证变长整数和容器边界；只有 size 的全 1 值代表未知长度，不能直接转为数组索引。
    nonisolated private static func ebmlElement(in bytes: [UInt8], at offset: Int, limit: Int) -> (id: UInt64, payload: Int, size: UInt64?)? {
        guard offset >= 0, offset < limit, limit <= bytes.count else { return nil }
        let idLength = bytes[offset].leadingZeroBitCount + 1
        guard idLength <= 4, idLength <= limit - offset else { return nil }
        let id = bytes[offset..<(offset + idLength)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let sizeOffset = offset + idLength
        guard sizeOffset < limit else { return nil }
        let sizeLength = bytes[sizeOffset].leadingZeroBitCount + 1
        guard sizeLength <= 8, sizeLength <= limit - sizeOffset else { return nil }
        var size = UInt64(bytes[sizeOffset] & (0xff >> sizeLength))
        for index in (sizeOffset + 1)..<(sizeOffset + sizeLength) { size = (size << 8) | UInt64(bytes[index]) }
        let unknownSize = (UInt64(1) << (7 * sizeLength)) - 1
        return (id, sizeOffset + sizeLength, size == unknownSize ? nil : size)
    }

    /// 启动有限缓存的流式转封装，首个分片就绪即可播放，无需先下载整部影片。
    static func start(channel: TVChannel, startTime: Double = 0, sourceDuration: Double? = nil) async throws -> MediaRemuxSession {
        guard startTime.isFinite, startTime >= 0 else {
            throw SourceParseError.invalidInput("播放位置无效，请重新选择进度。")
        }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("media/ffmpeg")
        let runtime = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TVBoxMacOS/runtime/media/ffmpeg")
        guard let executable = [bundled, runtime].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw SourceParseError.invalidInput("此资源实际为 MKV，缺少兼容播放组件。请重新安装包含该组件的应用版本。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tvbox-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let server = LocalMediaHTTPServer(directory: directory)
        let process = Process()
        var session: MediaRemuxSession?
        do {
            let baseURL = try await server.start()
            try Task.checkCancellation()
            process.executableURL = executable
            process.currentDirectoryURL = directory
            let headers = playbackHTTPHeaders(overrides: channel.headers).filter {
                !$0.key.contains("\r") && !$0.key.contains("\n") && !$0.value.contains("\r") && !$0.value.contains("\n")
            }.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
            let prefix = try await readPrefix(channel, count: 65_536)
            try Task.checkCancellation()
            let duration = sourceDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? matroskaDuration(in: prefix)
            let videoTag = prefix.range(of: Data("V_MPEGH/ISO/HEVC".utf8)) != nil ? ["-tag:v", "hvc1"] : []
            // 输入定位允许跳到尚未缓存的位置；新 HLS 的时间轴始终从零开始，由播放器叠加原片偏移。
            let seekArguments = startTime > 0 ? ["-ss", String(startTime)] : []
            process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                "-rw_timeout", "15000000", "-protocol_whitelist", "http,https,tcp,tls,crypto",
                "-headers", headers, "-readrate", "1", "-readrate_initial_burst", "12"] + seekArguments + ["-i", channel.streamURL.absoluteString,
                "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-c:v", "copy"] + videoTag + [
                "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-avoid_negative_ts", "make_zero", "-f", "hls", "-hls_time", "4",
                "-hls_segment_type", "fmp4", "-hls_list_size", "120", "-hls_delete_threshold", "2",
                "-hls_flags", "delete_segments+temp_file", "-hls_segment_filename", "segment-%06d.m4s", "index.m3u8"]
            // 不持久化 FFmpeg 原始错误文本，其中可能包含签名 URL 或 Cookie。
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let created = MediaRemuxSession(playbackURL: baseURL.appendingPathComponent("index.m3u8"), sourceDuration: duration, startTime: startTime, process: process, server: server, directory: directory)
            session = created
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline {
                try Task.checkCancellation()
                if let playlist = try? String(contentsOf: directory.appendingPathComponent("index.m3u8"), encoding: .utf8), playlist.contains("#EXTINF:") {
                    return created
                }
                guard process.isRunning else {
                    throw SourceParseError.invalidInput("MKV 兼容播放准备失败（退出码 \(process.terminationStatus)），请切换其他线路或画质。")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw SourceParseError.invalidInput("兼容播放准备超时，请检查线路速度或切换其他线路。")
        } catch {
            if let session { session.stop() }
            else { server.stop(); try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    /// 非零退出代表后台媒体读取或转换失败；成功结束的播放清单仍可继续使用。
    var failureExitCode: Int32? { !process.isRunning && process.terminationStatus != 0 ? process.terminationStatus : nil }

    /// 换集、停止和退出时终止转封装，并清除本次播放缓存。
    func stop() { Self.cleanup(process: process, server: server, directory: directory) }

    /// 进程只写本次临时分片；立即终止可避免应用退出后残留后台下载。
    nonisolated private static func cleanup(process: Process, server: LocalMediaHTTPServer, directory: URL) {
        server.stop()
        if process.isRunning {
            process.terminationHandler = { _ in try? FileManager.default.removeItem(at: directory) }
            kill(process.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

}

/// 只监听 loopback，使用随机路径，只提供本次会话的清单和分片。
final class LocalMediaHTTPServer: @unchecked Sendable {
    private let directory: URL
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "tvbox.media.http")
    private var listener: NWListener?
    // 只在 listener 的串行 queue 上读取并完成 continuation。
    private var startCompletion: CheckedContinuation<URL, Error>?

    init(directory: URL) { self.directory = directory }

    /// 异步等待系统分配端口，避免主线程阻塞。
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startCompletion = continuation
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let completion = self.startCompletion else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else { return }
                        self.startCompletion = nil
                        completion.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)")!)
                    case .failed(let error): self.startCompletion = nil; completion.resume(throwing: error)
                    case .cancelled: self.startCompletion = nil; completion.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: { listener.cancel() }
    }

    /// 停止接受连接；每个已接受的请求在发送响应后自动关闭。
    func stop() { listener?.cancel() }

    /// 分段收取 HTTP 头，限制大小与等待时间，防止本地连接长期占用资源。
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        receive(connection, buffered: Data(), timeout: timeout)
    }

    /// 只支持播放器需要的 GET/HEAD 和单段 Range。
    private func receive(_ connection: NWConnection, buffered: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = buffered
            if let data { request.append(data) }
            guard request.count <= 8192, error == nil else { connection.cancel(); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                timeout.cancel()
                self.respond(connection, request: String(decoding: request, as: UTF8.self))
            } else if complete { timeout.cancel(); connection.cancel() }
            else { self.receive(connection, buffered: request, timeout: timeout) }
        }
    }

    /// 严格限定文件名，不允许路径穿越，也不暴露其他临时文件。
    private func respond(_ connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])) else {
            send(connection, status: "405 Method Not Allowed", headers: [:], data: Data()); return
        }
        let prefix = "/\(token)/"
        let path = String(first[1])
        guard path.hasPrefix(prefix) else { send(connection, status: "404 Not Found", headers: [:], data: Data()); return }
        let name = String(path.dropFirst(prefix.count))
        guard Self.isAllowedFilename(name), let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            send(connection, status: "404 Not Found", headers: [:], data: Data()); return
        }
        var headers = ["Content-Type": name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4", "Cache-Control": "no-store", "Accept-Ranges": "bytes"]
        let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") }).map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        var body = data
        var status = "200 OK"
        if let rangeHeader {
            guard let range = Self.byteRange(rangeHeader, length: data.count) else {
                send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(data.count)"], data: Data()); return
            }
            body = data.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            status = "206 Partial Content"
        }
        headers["Content-Length"] = String(body.count)
        send(connection, status: status, headers: headers, data: first[0] == "HEAD" ? Data() : body)
    }

    /// 仅允许 FFmpeg 本会话创建的固定名称文件。
    static func isAllowedFilename(_ name: String) -> Bool {
        name == "index.m3u8" || name == "init.mp4" || name.range(of: #"^segment-[0-9]{6,}\.m4s$"#, options: .regularExpression) != nil
    }

    /// 解析闭区间、开放结尾和后缀 Range，限制到现有文件大小。
    static func byteRange(_ value: String, length: Int) -> Range<Int>? {
        guard length > 0, value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start >= 0, start < length else { return nil }
        if parts[1].isEmpty { return start..<length }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return start..<(min(end, length - 1) + 1)
    }

    /// 单请求单连接，Content-Length 避免客户端等待连接结束才解析分片。
    private func send(_ connection: NWConnection, status: String, headers: [String: String], data: Data) {
        var headers = headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(data.count) }
        let head = "HTTP/1.1 \(status)\r\nConnection: close\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
