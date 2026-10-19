import Foundation

/// 将 Android 内的媒体代理映射到 Mac；保留端口以兼容清单中的绝对分片地址。
enum SpiderPlaybackProxy {
    /// 仅转发 Spider 的回环地址；公网 CDN 地址保持原样。
    static func prepare(_ url: URL, serial: String,
                        runADB: ([String]) async throws -> String) async throws -> URL {
        guard let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return url }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else {
            throw SourceParseError.invalidInput("Spider 返回了无效的媒体代理端口。")
        }
        let endpoint = "tcp:\(port)"
        let forwards = try await runADB(["forward", "--list"])
        let existing = forwards.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .first { $0.count == 3 && $0[1] == endpoint }
        if let existing {
            guard existing[0] == serial, existing[2] == endpoint else {
                throw SourceParseError.invalidInput("本机媒体代理端口 \(port) 已被其他 Android 转发占用，请关闭冲突服务后重试。")
            }
        } else {
            do {
                _ = try await runADB(["-s", serial, "forward", "--no-rebind", endpoint, endpoint])
            } catch {
                throw SourceParseError.invalidInput("无法连接 Android 媒体代理（端口 \(port)）。请检查 Spider 服务是否就绪，或该端口是否被其他程序占用。")
            }
        }
        // adb 在 Mac 上监听 IPv4；只改主机，不解码带签名的 query/path。
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SourceParseError.invalidInput("Spider 媒体代理地址无效。")
        }
        components.host = "127.0.0.1"
        guard let forwarded = components.url else { throw SourceParseError.invalidInput("Spider 媒体代理地址无效。") }
        return forwarded
    }

    /// 在后台执行有超时的 adb 命令，避免设备失联时阻塞主界面。
    static func runADB(at executable: URL, arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SourceParseError.invalidInput("Android 端口转发失败或超时，请稍后重试。")
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
