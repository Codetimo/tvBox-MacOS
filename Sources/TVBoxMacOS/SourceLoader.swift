import Foundation

enum SourceLoaderError: LocalizedError {
    case unsupportedURL
    case emptyResponse
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedURL: return "请输入 http 或 https 地址。"
        case .emptyResponse: return "源返回内容为空。"
        case .unsupportedFormat: return "暂时只支持 M3U 和静态 TVBox JSON。"
        }
    }
}

struct SourceLoader {
    var session: URLSession = .shared

    func load(url: URL) async throws -> SourceSnapshot {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw SourceLoaderError.unsupportedURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty else { throw SourceLoaderError.emptyResponse }

        let name = url.host ?? "Remote source"
        let sourceKind: SourceKind = data.first == 35 || data.first == 239 ? .m3u : .tvboxJSON
        let source = TVSource(name: name, location: url, kind: sourceKind)

        switch sourceKind {
        case .m3u:
            return try M3UAdapter().parse(data: data, source: source)
        case .tvboxJSON:
            return try TVBoxJSONAdapter().parse(data: data, source: source)
        }
    }
}
