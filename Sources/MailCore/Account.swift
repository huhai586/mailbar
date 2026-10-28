import Foundation

/// 一个已添加的 Gmail 账号。每个账号有自己的钥匙串 token 和自己的邮件库，互不影响。
public struct Account: Codable, Identifiable, Equatable, Sendable {
    /// 小写的邮箱地址
    public var id: String { email }
    public var email: String
    /// token 在钥匙串里的条目名
    public var tokenKey: String
    /// 这个账号的邮件库文件
    public var dbPath: String
    /// 界面上区分账号的颜色（Theme 里的调色板序号）
    public var colorIndex: Int
    public var addedAt: Date

    public init(email: String, tokenKey: String, dbPath: String, colorIndex: Int, addedAt: Date = Date()) {
        self.email = email.lowercased()
        self.tokenKey = tokenKey
        self.dbPath = dbPath
        self.colorIndex = colorIndex
        self.addedAt = addedAt
    }
}

/// 账号清单（`accounts.json`）：哪些账号、各自的邮件库在哪。
public struct AccountRegistry: Equatable, Sendable {
    public private(set) var accounts: [Account]

    public init(accounts: [Account] = []) { self.accounts = accounts }

    // MARK: - 增删

    public func account(id: String) -> Account? { accounts.first { $0.id == id.lowercased() } }

    /// 添加账号：已经有同一个邮箱就返回 nil（不重复添加）。邮件库放在 `directory` 下，颜色挑一个还没人用的。
    @discardableResult
    public mutating func add(email: String, tokenKey: String, directory: String) -> Account? {
        let email = email.lowercased()
        guard account(id: email) == nil else { return nil }
        let used = Set(accounts.map(\.colorIndex))
        let color = (0..<Self.paletteSize).first { !used.contains($0) } ?? accounts.count % Self.paletteSize
        let file = Self.fileName(forEmail: email)
        let account = Account(email: email, tokenKey: tokenKey, dbPath: (directory as NSString).appendingPathComponent(file), colorIndex: color)
        accounts.append(account)
        return account
    }

    public mutating func remove(id: String) {
        accounts.removeAll { $0.id == id.lowercased() }
    }

    /// 界面调色板的颜色数（Theme.accountColors 和它保持一致）
    public static let paletteSize = 8

    /// 邮箱变成安全的文件名（`a@b.com` → `a@b.com.sqlite`，斜杠之类换成下划线）。
    static func fileName(forEmail email: String) -> String {
        let safe = email.lowercased().map { $0.isLetter || $0.isNumber || "@.-_+".contains($0) ? $0 : "_" }
        return String(safe) + ".sqlite"
    }

    // MARK: - 存取

    /// 账号清单的位置。MAIL_ACCOUNTS 优先；用 MAIL_DB 指向邮件库副本做测试时，清单放在副本旁边，绝不碰真实的那份。
    public static func defaultPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["MAIL_ACCOUNTS"] { return (custom as NSString).expandingTildeInPath }
        if env["MAIL_DB"] != nil { return MailStore.defaultPath() + ".accounts.json" }
        return ("~/Library/Application Support/MailClient/accounts.json" as NSString).expandingTildeInPath
    }

    /// 新账号的邮件库放在哪个目录。
    public static func defaultDirectory() -> String {
        (MailStore.defaultPath() as NSString).deletingLastPathComponent + "/accounts"
    }

    public static func read(from path: String = defaultPath()) -> AccountRegistry? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let accounts = try? decoder.decode([Account].self, from: data) else { return nil }
        return AccountRegistry(accounts: accounts)
    }

    public func write(to path: String = AccountRegistry.defaultPath()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try encoder.encode(accounts).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - 从单账号版本升级

    /// 读清单；还没有清单时，如果旧版本的邮件库里已经有账号邮箱，就把它登记为第一个账号（沿用原来的邮件库和钥匙串条目，数据一点不动）。
    /// 全新安装（没有清单、也没有旧邮件库）返回空清单，由界面引导添加账号。
    public static func load(path: String = defaultPath(), legacyDBPath: String = MailStore.defaultPath()) -> AccountRegistry {
        if let registry = read(from: path) { return registry }
        var registry = AccountRegistry()
        if FileManager.default.fileExists(atPath: legacyDBPath),
           let store = try? MailStore(path: legacyDBPath), let email = store.accountEmail, !email.isEmpty {
            let account = Account(email: email, tokenKey: OAuthClient.defaultTokenKey, dbPath: legacyDBPath, colorIndex: 0)
            registry = AccountRegistry(accounts: [account])
            try? registry.write(to: path)
        }
        return registry
    }
}
