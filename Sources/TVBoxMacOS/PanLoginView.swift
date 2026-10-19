import SwiftUI
import CoreImage.CIFilterBuiltins

/// 扫码接口只连接本机桥接；登录凭据不进入 URL 或日志。
struct PanLoginConnection {
    let site: TVBoxSite
    let baseURL: URL
    let token: String

    /// 独立扫码请求不携带旧 Cookie，避免轮询覆盖刚登录的账号。
    func request(action: String, provider: PanCookieStore.Provider, taskID: String? = nil) async throws -> PanLoginResponse {
        var body: [String: Any] = ["spider": site.spiderURL?.absoluteString ?? "",
                                    "md5": site.spiderMD5 ?? "", "provider": provider.rawValue, "action": action]
        body["taskId"] = taskID
        if action == "start" { body["pan_cookie_version"] = UserDefaults.standard.integer(forKey: "panCookieVersion") }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pan-login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(token, forHTTPHeaderField: "X-TVBox-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let envelope = try? JSONDecoder().decode(PanLoginEnvelope.self, from: data), envelope.ok,
              let result = envelope.data else {
            throw SourceParseError.invalidInput("扫码服务暂不可用，请检查网络或更新站源后重试。")
        }
        return result
    }
}

private struct PanLoginEnvelope: Decodable {
    let ok: Bool
    let data: PanLoginResponse?
}

struct PanLoginResponse: Decodable {
    var taskId: String?
    var qrUrl: String?
    var status: String?
    var terminal: Bool?
    var cookie: String?

    /// 只接受含身份字段的 Cookie；访客标识不能作为登录成功依据。
    func authenticatedCookie(for provider: PanCookieStore.Provider) -> String? {
        guard let cookie, !cookie.contains(where: \.isNewline) else { return nil }
        let fields = cookie.split(separator: ";").compactMap { field -> String? in
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return provider.authenticationCookieNames.isDisjoint(with: Set(fields)) ? nil : cookie
    }

    /// 文本在本机编码成二维码，已有图片则直接解码，不加载网页或远程图片。
    static func qrImage(_ payload: String) -> NSImage? {
        guard !payload.isEmpty, payload.utf8.count <= 1_000_000 else { return nil }
        if payload.hasPrefix("data:image/") {
            guard let comma = payload.firstIndex(of: ","), payload[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(payload[payload.index(after: comma)...])) else { return nil }
            return NSImage(data: data)
        }
        guard payload.utf8.count <= 2953 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                                                     from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 原生二维码弹窗；SwiftUI task 的取消机制隔离刷新和关闭后的旧回调。
struct PanLoginView: View {
    let provider: PanCookieStore.Provider
    let prepare: () async throws -> [PanLoginConnection]
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var message = "正在准备二维码…"
    @State private var saved = false
    @State private var failed = false
    @State private var sessionID = UUID()

    var body: some View {
        VStack(spacing: 18) {
            Text("登录\(provider.title)").font(.title3.bold())
            Text("使用\(provider.title) App 扫码并确认登录").font(.callout).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.white)
                if let image {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(16)
                } else if saved {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                } else if failed {
                    Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(.gray)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 264, height: 264)
            Text(message).font(.callout).foregroundStyle(failed ? Color.red : Color.secondary)
                .multilineTextAlignment(.center).frame(height: 42)
            HStack(spacing: 16) {
                if !saved { Button("刷新二维码") { sessionID = UUID() } }
                Button(saved ? "完成" : "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("登录信息保存在本机钥匙串").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 380, height: 490)
        .task(id: sessionID) { await login() }
    }

    /// 单次会话串行轮询；刷新、关闭、超时和错误都会取消服务端任务。
    @MainActor private func login() async {
        image = nil; saved = false; failed = false; message = "正在准备二维码…"
        var activeConnection: PanLoginConnection?
        var taskID: String?
        defer {
            if let activeConnection, let taskID {
                Task { _ = try? await activeConnection.request(action: "cancel", provider: provider, taskID: taskID) }
            }
        }
        do {
            let connections = try await prepare()
            try Task.checkCancellation()
            for connection in connections {
                do {
                    let result = try await connection.request(action: "start", provider: provider)
                    activeConnection = connection; taskID = result.taskId
                    try Task.checkCancellation()
                    guard let id = result.taskId, !id.isEmpty, let qr = result.qrUrl,
                          let rendered = PanLoginResponse.qrImage(qr) else {
                        throw SourceParseError.invalidInput("站源未返回有效二维码，请更新站源后重试。")
                    }
                    image = rendered
                    break
                } catch {
                    try Task.checkCancellation()
                    if let taskID { _ = try? await connection.request(action: "cancel", provider: provider, taskID: taskID) }
                    activeConnection = nil; taskID = nil
                }
            }
            guard let connection = activeConnection, let id = taskID else {
                throw SourceParseError.invalidInput("无法获取二维码，请检查网络，并确认站源支持网盘扫码登录。")
            }
            message = "等待扫码并确认登录…"
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let result = try await connection.request(action: "poll", provider: provider, taskID: id)
                try Task.checkCancellation()
                if result.status == "success" {
                    guard let cookie = result.authenticatedCookie(for: provider) else {
                        throw SourceParseError.invalidInput("未获取到有效登录信息，请刷新二维码重试。")
                    }
                    try PanCookieStore.shared.save(cookie: cookie, for: provider)
                    image = nil; saved = true; message = "登录成功，登录信息已保存"
                    return
                }
                if result.terminal == true {
                    throw SourceParseError.invalidInput("二维码已失效或登录已取消，请刷新二维码。")
                }
                message = result.status == "scanned" ? "已扫码，请在手机上确认登录…" : "等待扫码并确认登录…"
            }
            throw SourceParseError.invalidInput("二维码已过期，请刷新二维码。")
        } catch {
            guard !Task.isCancelled else { return }
            image = nil; failed = true
            // URLSession 错误不透传，以免含会话信息的 URL 出现在界面中。
            message = (error as? SourceParseError)?.localizedDescription
                ?? (error as? PanCookieStore.CredentialError)?.localizedDescription
                ?? "二维码加载失败，请检查网络后刷新。"
        }
    }
}
