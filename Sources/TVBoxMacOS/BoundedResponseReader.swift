import Foundation

/// 对实际收到的字节和整次请求耗时设限，避免错误源地址占满内存或持续滴流。
enum BoundedResponseReader {
    static let maximumBytes = 10 * 1024 * 1024

    /// 使用调用方的会话配置（包括 URLProtocol、代理和 Cookie），每次请求独立取消。
    static func read(_ request: URLRequest, session: URLSession,
                     maximumBytes: Int = maximumBytes, timeout: TimeInterval? = nil,
                     prefixCheckpoints: [Int] = [], stopReading: ((Data, URLResponse) -> Bool)? = nil) async throws -> (Data, URLResponse) {
        let operation = ResponseOperation(configuration: session.configuration, request: request,
                                          maximumBytes: maximumBytes, timeout: timeout ?? request.timeoutInterval,
                                          prefixCheckpoints: prefixCheckpoints, stopReading: stopReading)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }
}

/// 委托回调逐块累计；锁保护取消发生在任务创建之前、响应期间和完成之后的竞态。
private final class ResponseOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private let maximumBytes: Int
    private let timeout: TimeInterval
    private let prefixCheckpoints: [Int]
    private let stopReading: ((Data, URLResponse) -> Bool)?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var result: Result<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var response: URLResponse?
    private var data = Data()

    /// 参数由读取入口固定；会话沿用提供方配置，避免绕过测试协议和用户网络设置。
    init(configuration: URLSessionConfiguration, request: URLRequest, maximumBytes: Int, timeout: TimeInterval,
         prefixCheckpoints: [Int], stopReading: ((Data, URLResponse) -> Bool)?) {
        self.configuration = configuration
        self.request = request
        self.maximumBytes = maximumBytes
        self.timeout = timeout
        self.prefixCheckpoints = prefixCheckpoints.filter { $0 > 0 && $0 <= maximumBytes }.sorted()
        self.stopReading = stopReading
    }

    /// 原子地注册 continuation 和任务，确保调用方提前取消也只完成一次。
    func start(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
        self.deadline = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        task.resume()
        lock.unlock()
    }

    /// 声明长度仅用于提前拒绝；未知长度或虚假长度仍由实际数据回调约束。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // 已明确为媒体或错误响应时无需下载正文；声明巨大媒体长度也可以立即结束探测。
        if stopReading?(Data(), response) == true {
            finish(.success((Data(), response)))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(SourceParseError.invalidInput("响应超过允许的大小限制。")))
            return
        }
        lock.lock()
        self.response = response
        let active = result == nil
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    /// 按检查点拆分回调数据；媒体探测最多保留所需前缀，其余响应仍受实际字节上限保护。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard result == nil, let response else { lock.unlock(); return }
        var offset = 0
        for checkpoint in prefixCheckpoints where checkpoint > data.count {
            let length = checkpoint - data.count
            guard length <= chunk.count - offset else { break }
            data.append(chunk.subdata(in: offset..<(offset + length)))
            offset += length
            if stopReading?(data, response) == true {
                let prefix = data
                lock.unlock()
                finish(.success((prefix, response)))
                return
            }
        }
        let exceeded = chunk.count - offset > maximumBytes - data.count
        if !exceeded { data.append(chunk.subdata(in: offset..<chunk.count)) }
        lock.unlock()
        if exceeded { finish(.failure(SourceParseError.invalidInput("响应超过允许的大小限制。"))) }
    }

    /// 完成时只交付已验证的响应，错误和主动取消通过同一出口清理资源。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let response = self.response
        let data = self.data
        lock.unlock()
        if let response { finish(.success((data, response))) }
        else { finish(.failure(URLError(.badServerResponse))) }
    }

    /// 唯一完成出口，释放会话委托并恢复等待者，重复回调不产生副作用。
    func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        let task = self.task
        self.task = nil
        deadline?.cancel()
        deadline = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
