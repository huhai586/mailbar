import Foundation

public enum MailError: LocalizedError {
    case config(String)
    case keychain(OSStatus)
    case oauth(code: String, description: String?)
    case http(status: Int, body: String)
    case timeout
    case historyExpired
    case loginRequired
    case reauthorizationRequired

    public var errorDescription: String? {
        switch self {
        case .loginRequired: return "需要重新登录 Google 账号"
        case .reauthorizationRequired: return "需要升级授权（允许修改邮件状态）后才能标记已读"
        case .historyExpired: return "historyId 已过期，需要全量重新同步"
        case .config(let m): return m
        case .keychain(let s): return "Keychain 错误: OSStatus \(s)"
        case .oauth(let code, let desc): return "OAuth 失败: \(code)\(desc.map { " - \($0)" } ?? "")"
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .timeout: return "等待浏览器授权超时（5 分钟）"
        }
    }
}

public struct ClientConfig: Sendable {
    let clientID: String
    let clientSecret: String

    static let defaultPath = "~/.config/mail-client/client_secret.json"

    /// 客户端文件的位置（MAIL_CLIENT_JSON 优先）。
    public static var filePath: String {
        let raw = ProcessInfo.processInfo.environment["MAIL_CLIENT_JSON"] ?? defaultPath
        return (raw as NSString).expandingTildeInPath
    }

    /// 读取 GCP 控制台下载的"桌面应用" OAuth 客户端 JSON。
    public static func load() throws -> ClientConfig {
        let path = filePath
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MailError.config("找不到 OAuth 客户端文件: \(path)\n在 设置 → 账号与同步 里导入 GCP 下载的 JSON，或把它放到该位置。")
        }
        return try parse(data)
    }

    /// 解析并校验客户端 JSON。给出能看懂的错误：常见的是下成了"Web 应用"类型的客户端。
    public static func parse(_ data: Data) throws -> ClientConfig {
        struct Inner: Decodable { let client_id: String; let client_secret: String }
        struct Root: Decodable { let installed: Inner?; let web: Inner? }
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) } catch {
            throw MailError.config("这不是 GCP 下载的 OAuth 客户端 JSON。")
        }
        guard let inner = root.installed else {
            throw MailError.config(root.web != nil
                ? "这是「Web 应用」类型的客户端，需要「桌面应用」类型。回到 GCP 控制台重新创建一个桌面应用客户端并下载 JSON。"
                : "JSON 里没有 \"installed\" 字段，需要「桌面应用」类型客户端的 JSON。")
        }
        guard !inner.client_id.isEmpty, !inner.client_secret.isEmpty else { throw MailError.config("JSON 里的 client_id 或 client_secret 是空的。") }
        return ClientConfig(clientID: inner.client_id, clientSecret: inner.client_secret)
    }

    /// 校验后把一个客户端 JSON 装到应用读取的位置（权限 600）。返回安装后的客户端 ID。
    @discardableResult
    public static func install(from source: URL, to destination: String = filePath) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: source) } catch { throw MailError.config("读不了这个文件：\(error.localizedDescription)") }
        let config = try parse(data)
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
        return config.clientID
    }

    /// 当前已配置的客户端 ID（没配置或格式不对返回 nil）。只给界面显示用，不含密钥。
    public static func installedClientID() -> String? {
        (try? load())?.clientID
    }
}
