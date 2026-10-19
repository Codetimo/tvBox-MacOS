import Foundation
import Security
import Combine

/// 负责保存网盘登录 Cookie。Cookie 属于凭据，使用 macOS Keychain 而不是 UserDefaults。
final class PanCookieStore: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case quark
        case baidu

        var id: String { rawValue }
        var title: String { self == .quark ? "夸克网盘" : "百度网盘" }
        var domains: [String] { self == .quark ? ["quark.cn"] : ["baidu.com"] }
        var loginURL: URL { URL(string: self == .quark ? "https://pan.quark.cn/" : "https://pan.baidu.com/")! }

        /// 必须具备身份 Cookie，访客标识（如 BAIDUID）不代表登录成功。
        var authenticationCookieNames: Set<String> {
            self == .quark ? ["__pus", "__puus"] : ["bduss"]
        }

        /// 仅接受官方域名及其子域名，避免将相似域名的 Cookie 当成凭据。
        func accepts(domain: String) -> Bool {
            let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    struct CredentialError: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? { "\(operation)失败（钥匙串错误 \(status)），请重试。" }
    }

    struct BridgeSnapshot {
        let cookies: [String: String]
        let version: Int
    }

    static let shared = PanCookieStore()
    private let service = "com.codetimo.tvbox-macos.pan-cookie"
    private let lock = NSLock()
    @Published private(set) var revision = 0

    private init() {}

    /// 返回当前提供商的 Cookie 请求头内容。
    func cookie(for provider: Provider) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let data = read(provider: provider), let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// 设置页仅检查记录元数据，不读取 Cookie，也不触发钥匙串授权弹窗。
    func credentialStatus(for provider: Provider) -> OSStatus {
        var query = keychainQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    /// 原位更新凭据；更新失败时保留原凭据，并向界面报告错误。
    func save(cookie: String, for provider: Provider) throws {
        let value = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CredentialError(operation: "保存登录信息", status: errSecParam) }
        // 先读取旧值再加写锁，避免在同一把 NSLock 上嵌套加锁。
        if self.cookie(for: provider) == value { return }
        lock.lock(); defer { lock.unlock() }
        let query = keychainQuery(provider)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError(operation: "保存登录信息", status: status) }
        UserDefaults.standard.set(true, forKey: "panCookieManaged.\(provider.rawValue)")
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "panCookieVersion") + 1, forKey: "panCookieVersion")
        DispatchQueue.main.async { self.revision += 1 }
    }

    /// 删除本机凭据，并记录显式退出以清除 Spider 保存的登录信息。
    func remove(provider: Provider) throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(keychainQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError(operation: "清除登录信息", status: status)
        }
        UserDefaults.standard.set(true, forKey: "panCookieManaged.\(provider.rawValue)")
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "panCookieVersion") + 1, forKey: "panCookieVersion")
        DispatchQueue.main.async { self.revision += 1 }
    }

    /// Only explicit account changes are sent to the bridge; a Keychain access error must never clear an account.
    func bridgeSnapshot() throws -> BridgeSnapshot {
        lock.lock(); defer { lock.unlock() }
        var values: [String: String] = [:]
        for provider in Provider.allCases {
            var query = keychainQuery(provider)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data,
               let value = String(data: data, encoding: .utf8) {
                values[provider.rawValue] = value
            } else if status == errSecItemNotFound {
                if UserDefaults.standard.bool(forKey: "panCookieManaged.\(provider.rawValue)") {
                    values[provider.rawValue] = "" // Persist the explicit logout across bridge restarts.
                }
            } else {
                throw CredentialError(operation: "读取登录信息", status: status)
            }
        }
        return BridgeSnapshot(cookies: values, version: UserDefaults.standard.integer(forKey: "panCookieVersion"))
    }

    /// 提取完整、未过期的官方身份 Cookie，稳定排序避免同一凭据反复写入。
    static func authenticatedHeader(cookies: [HTTPCookie], provider: Provider, now: Date = Date()) -> String? {
        let matched = cookies.filter {
            provider.accepts(domain: $0.domain) && !$0.value.isEmpty &&
                ($0.expiresDate.map { $0 > now } ?? true) &&
                !$0.name.contains(where: { $0.isNewline }) && !$0.value.contains(where: { $0.isNewline })
        }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.value < $1.value
        }
        let names = Set(matched.map { $0.name.lowercased() })
        // 百度要求 BDUSS；夸克的 __pus / __puus 随网页版本二选一即可。
        guard !provider.authenticationCookieNames.isDisjoint(with: names) else { return nil }
        var seen = Set<String>()
        return matched.filter { seen.insert($0.name).inserted }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 将 Cookie 合并到 JSON 配置。URL、文本等其他 ext 格式必须原样保留。
    static func spiderExtension(base: String?, quark: String?, baidu: String?) -> String {
        var object: [String: Any] = [:]
        if let base, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = base.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return base }
            object = decoded
        }
        if let quark {
            object["quark_cookie"] = quark
            object["quarkCookie"] = quark
        }
        if let baidu {
            object["baidu_cookie"] = baidu
            object["baiduCookie"] = baidu
        }
        guard !object.isEmpty, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return base ?? "" }
        return String(data: data, encoding: .utf8) ?? (base ?? "")
    }

    /// 构造提供商独立的钥匙串记录标识。
    private func keychainQuery(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
    }

    private func read(provider: Provider) -> Data? {
        var query = keychainQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
