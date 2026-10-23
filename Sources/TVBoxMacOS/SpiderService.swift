import Foundation
import Combine

/// 管理本机 Android Spider 桥接服务；launcher 负责模拟器和端口转发。
@MainActor
final class SpiderService: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case recovering
        case ready
        case unavailable(String)
        case failed(String)

        var message: String {
            switch self {
            case .stopped: return "Spider 服务未启动"
            case .starting: return "正在启动本地 Spider 服务…"
            case .recovering: return "本地 Spider 服务连接中断，正在恢复…"
            case .ready: return "本地 Spider 服务已就绪"
            case .unavailable(let reason), .failed(let reason): return reason
            }
        }
    }

    let port: Int
    let baseURL: URL
    let token: String
    @Published private(set) var state: State = .stopped
    private var process: Process?
    private var setupProcess: Process?
    private var generation = UUID()
    private var monitorTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupID = UUID()
    private let session: URLSession
    private let monitorInterval: UInt64

    init(port: Int = 19190, session: URLSession = .shared, monitorInterval: UInt64 = 2_000_000_000) {
        self.port = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.session = session
        self.monitorInterval = monitorInterval
    }

    var isReady: Bool { state == .ready }

    /// 所有业务请求共用就绪检查；取消单个调用者不会取消其他窗口的共享启动任务。
    func ensureReady() async throws {
        try Task.checkCancellation()
        await start()
        try Task.checkCancellation()
        guard await waitUntilReady() else {
            try Task.checkCancellation()
            throw SourceParseError.invalidInput(state.message)
        }
        try Task.checkCancellation()
    }

    /// 播放前建立媒体通道；adb 会在本服务的模拟器退出时移除对应转发。
    func preparePlaybackURL(_ url: URL) async throws -> URL {
        let attempt = generation
        let environment = ProcessInfo.processInfo.environment
        let serial = environment["TVBOX_ANDROID_SERIAL"] ?? "emulator-\(environment["TVBOX_EMULATOR_PORT"] ?? "5580")"
        let adb = runtimeURL.appendingPathComponent("android-sdk/platform-tools/adb")
        let forwarded = try await SpiderPlaybackProxy.prepare(url, serial: serial) { arguments in
            try await SpiderPlaybackProxy.runADB(at: adb, arguments: arguments)
        }
        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
        return forwarded
    }

    /// 等待当前启动任务完成，避免用户在模拟器启动期间搜索时跳过所有 Spider 站点。
    func waitUntilReady(timeout: TimeInterval = 360) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .ready:
                // 健康状态由 startMonitoring 每 2 秒刷新。搜索路径不再重复发起
                // 1.5 秒的 HTTP health 请求，避免每个批次都额外阻塞一次。
                return true
            case .failed, .unavailable, .stopped:
                return false
            case .starting, .recovering:
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return false }
            }
        }
        return isReady
    }

    /// 各窗口共用独立启动任务；搜索等待被取消不会终止其他窗口正在使用的服务。
    func start() async {
        if startupTask != nil { await waitForStartup(identifier: startupID); return }
        let identifier = UUID()
        startupID = identifier
        let task = Task { [weak self] in
            guard let self else { return }
            await performStart()
            if startupID == identifier { startupTask = nil }
        }
        startupTask = task
        await waitForStartup(identifier: identifier)
    }

    /// 等待者可单独取消，避免旧搜索在共享服务漫长的首次启动期间无法退出。
    private func waitForStartup(identifier: UUID) async {
        while startupID == identifier, startupTask != nil {
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return }
        }
    }

    /// 启动 launcher 并等待服务；generation 防止停止后旧异步任务重新启动服务。
    private func performStart() async {
        guard process == nil, setupProcess == nil, monitorTask == nil, state != .starting else { return }
        let attempt = UUID()
        generation = attempt
        // MainActor 会在 await 期间允许其他调用进入，必须先占用启动状态。
        state = .starting

        // App 重载或 launcher 被外部重启时，端口上的桥接服务可能已经就绪，
        // 这时直接复用现有服务，避免再次准备运行时和启动 Android 模拟器。
        let alreadyHealthy = await healthCheck()
        guard generation == attempt else { return }
        guard !Task.isCancelled else { stop(); return }
        if alreadyHealthy {
            state = .ready
            startMonitoring(attempt: attempt)
            return
        }

        if !runtimeIsPrepared() {
            guard let setup = scriptURL("setup_spider_runtime.sh") else {
                state = .unavailable("未找到 Android 运行时准备脚本，请重新安装 App。")
                return
            }
            let prepared = await runSetup(setup)
            guard generation == attempt else { return }
            guard !Task.isCancelled else { stop(); return }
            guard prepared else {
                state = .failed("Android 运行时准备失败，日志：\(runtimeURL.appendingPathComponent("logs/setup.log").path)")
                return
            }
        }
        guard generation == attempt else { return }
        guard !Task.isCancelled else { stop(); return }
        guard let launcher = scriptURL("spider-service/launch.sh") else {
            state = .unavailable("未找到 Spider 启动脚本，请重新安装 App。")
            return
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = [launcher.path, "--port", String(port), "--token", token]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "TVBOX_SPIDER_PORT": String(port), "TVBOX_SPIDER_TOKEN": token,
            "TVBOX_RUNTIME_DIR": runtimeURL.path
        ]) { _, new in new }
        let log = logHandle("spider-service.log")
        child.standardOutput = log
        child.standardError = log
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.process === terminated { self.process = nil }
                guard self.generation == attempt else { return }
                self.monitorTask?.cancel()
                self.monitorTask = nil
                self.state = .failed("Spider 服务已退出（状态码 \(terminated.terminationStatus)），日志：\(self.runtimeURL.appendingPathComponent("logs").path)")
            }
        }
        do {
            process = child
            try child.run()
        } catch {
            process = nil
            state = .failed("Spider 服务启动失败：\(error.localizedDescription)")
            return
        }

        // 与 launcher 首次启动预算保持一致；以实际时间计，避免网络请求延长超时。
        let deadline = Date().addingTimeInterval(360)
        while Date() < deadline {
            guard generation == attempt else { return }
            guard !Task.isCancelled else { stop(); return }
            guard child.isRunning else { return }
            let healthy = await healthCheck()
            guard generation == attempt else { return }
            if healthy { state = .ready; startMonitoring(attempt: attempt); return }
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch {
                // 旧启动任务的取消可能晚于新会话创建，只允许它停止自己的 generation。
                if generation == attempt { stop() }
                return
            }
        }
        state = .failed("Spider 服务启动超时，日志：\(runtimeURL.appendingPathComponent("logs").path)")
        stop()
    }

    /// 停止准备任务和 launcher；失败状态保留，清理由 launcher 的退出处理完成。
    func stop() {
        generation = UUID()
        startupID = UUID()
        startupTask?.cancel()
        startupTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        if let setupProcess, setupProcess.isRunning { setupProcess.terminate() }
        if let process, process.isRunning { process.terminate() }
        // setupProcess 在等待退出时仍保留引用，避免重入准备任务。
        if case .failed = state { return }
        state = .stopped
    }

    /// 持续刷新真实健康状态；恢复由 launcher 负责，避免两层同时重启模拟器。
    private func startMonitoring(attempt: UUID) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.monitorInterval else { return }
                do { try await Task.sleep(nanoseconds: interval) }
                catch { return }
                guard let self, self.generation == attempt else { return }
                if let process = self.process, !process.isRunning { return }
                let healthy = await self.healthCheck()
                guard self.generation == attempt, !Task.isCancelled else { return }
                if let process = self.process, !process.isRunning { return }
                self.state = healthy ? .ready : .recovering
            }
        }
    }

    /// 只接受携带本次会话令牌的健康响应。
    private func healthCheck() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1.5
        request.setValue(token, forHTTPHeaderField: "X-TVBox-Token")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ready"] as? Bool) == true else { return false }
        return true
    }

    /// App 资源与开发工作区保持同样的 scripts/Bridge 相对目录。
    private func scriptURL(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("scripts/\(name)")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/\(name)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var runtimeURL: URL {
        if let override = ProcessInfo.processInfo.environment["TVBOX_RUNTIME_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMacOS/runtime", isDirectory: true)
    }

    /// 不能只检查 adb；下载中断时其他运行时组件可能尚未完成。
    private func runtimeIsPrepared() -> Bool {
        let files = ["android-sdk/platform-tools/adb", "android-sdk/emulator/emulator", "jdk-17/bin/java",
                     "android-sdk/system-images/android-35/google_apis/arm64-v8a/system.img", "avd/tvbox-spider.ini"]
        return files.allSatisfy { FileManager.default.fileExists(atPath: runtimeURL.appendingPathComponent($0).path) }
    }

    /// shell 包装器终止时递归停止它自己的下载/Java 子进程，不留下后台准备任务。
    private func runSetup(_ setup: URL) async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", """
        stop_tree() { for descendant in $(/usr/bin/pgrep -P "$1"); do stop_tree "$descendant"; done; kill -TERM "$1" 2>/dev/null || true; }
        child=""
        trap 'trap - TERM INT; [ -z "$child" ] || stop_tree "$child"; exit 143' TERM INT
        /bin/bash "$1" & child=$!
        wait "$child"
        """, "tvbox-setup", setup.path]
        task.environment = ProcessInfo.processInfo.environment.merging(["TVBOX_RUNTIME_DIR": runtimeURL.path]) { _, new in new }
        let log = logHandle("setup.log")
        task.standardOutput = log
        task.standardError = log
        setupProcess = task
        let succeeded: Bool = await withCheckedContinuation { continuation in
            task.terminationHandler = { process in continuation.resume(returning: process.terminationStatus == 0) }
            do { try task.run() } catch { continuation.resume(returning: false) }
        }
        setupProcess = nil
        return succeeded
    }

    /// 创建可追加日志，避免 App 从 Finder 启动时错误信息丢失。
    private func logHandle(_ name: String) -> FileHandle {
        let directory = runtimeURL.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name).path
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return FileHandle.standardError }
        _ = try? handle.seekToEnd()
        return handle
    }
}
