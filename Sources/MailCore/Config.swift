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

    /// 读取 GCP 控制台下载的"桌面应用" OAuth 客户端 JSON。
    public static func load() throws -> ClientConfig {
        let raw = ProcessInfo.processInfo.environment["MAIL_CLIENT_JSON"] ?? defaultPath
        let path = (raw as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MailError.config("找不到 OAuth 客户端文件: \(path)\n把 GCP 下载的 JSON 放到该位置，或用 MAIL_CLIENT_JSON 指定路径。")
        }
        struct Root: Decodable {
            struct Inner: Decodable { let client_id: String; let client_secret: String }
            let installed: Inner
        }
        do {
            let root = try JSONDecoder().decode(Root.self, from: data)
            return ClientConfig(clientID: root.installed.client_id, clientSecret: root.installed.client_secret)
        } catch {
            throw MailError.config("客户端 JSON 格式不对（需要 \"installed\" 字段，即'桌面应用'类型的客户端）: \(error)")
        }
    }
}
