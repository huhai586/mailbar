import CryptoKit
import Foundation

struct StoredToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    /// 授权时拿到的范围；旧版本存的 token 没有这个字段（nil 表示只读）
    var scope: String?

    var canModify: Bool { scope?.contains("gmail.modify") ?? false }
    /// 旧版本授权的范围里没有日历；要看日历需要重新授权一次
    var canReadCalendar: Bool { scope?.contains("auth/calendar") ?? false }
}

private final class TokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredToken?
    var token: StoredToken? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

public struct OAuthClient: Sendable {
    static let readScope = "https://www.googleapis.com/auth/gmail.readonly"
    /// 标记已读/未读需要 modify（包含读取权限）；日历只读用来在「日历」模块里显示日程
    static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let scope = "https://www.googleapis.com/auth/gmail.modify " + calendarScope
    /// 第一个账号（升级前就有的那个）的钥匙串条目名；之后添加的账号用 `gmail-oauth-token:<邮箱>`
    public static let defaultTokenKey = "gmail-oauth-token"
    static let account = defaultTokenKey

    let config: ClientConfig
    /// 这个账号的 token 在钥匙串里的条目名
    public let tokenKey: String
    /// false 时（常驻程序）需要登录会抛 loginRequired，而不是自己弹出浏览器。
    let interactive: Bool
    /// 拷贝共享：避免每个请求都读一次 Keychain
    private let cache = TokenCache()

    public init(config: ClientConfig, interactive: Bool = true, tokenKey: String = OAuthClient.defaultTokenKey) {
        self.config = config
        self.interactive = interactive
        self.tokenKey = tokenKey
    }

    /// 返回可用的 access token：优先用缓存，过期则刷新，没有则走浏览器登录。
    public func accessToken() async throws -> String {
        if let stored = loadToken() {
            if stored.expiry > Date().addingTimeInterval(60) { return stored.accessToken }
            do {
                return try await refresh(stored).accessToken
            } catch MailError.oauth(let code, _) where code == "invalid_grant" {
                if !interactive { throw MailError.loginRequired }
                print("refresh token 已失效，重新登录…")
            }
        }
        if !interactive { throw MailError.loginRequired }
        return try await login().accessToken
    }

    /// 当前 token 是否已授权修改邮件（标记已读/未读）。旧的只读授权需要重新登录一次。
    public var canModify: Bool { loadToken()?.canModify ?? false }

    /// 当前 token 是否已授权读取日历。
    public var canReadCalendar: Bool { loadToken()?.canReadCalendar ?? false }

    /// 主动登录（浏览器授权），常驻程序在 loginRequired 后由用户触发。
    /// loginHint：提示 Google 登录哪个邮箱（重新授权已有账号时用）。
    public func signIn(loginHint: String? = nil) async throws {
        _ = try await login(loginHint: loginHint)
    }

    /// 添加一个新账号：弹出浏览器让用户选 Google 账号，授权后用 profile 查出邮箱，token 存到以邮箱命名的钥匙串条目。
    /// 返回邮箱和条目名；同一个邮箱已经添加过也会走到这里，由调用方决定怎么处理。
    public static func addAccount(config: ClientConfig) async throws -> (email: String, tokenKey: String) {
        let pendingKey = "\(defaultTokenKey):pending"
        let temp = OAuthClient(config: config, tokenKey: pendingKey)
        defer { Keychain.delete(account: pendingKey) }
        _ = try await temp.login(loginHint: nil, selectAccount: true)
        let email = try await GmailClient(oauth: temp).profile().emailAddress.lowercased()
        let key = tokenKey(forEmail: email)
        guard let token = temp.loadToken() else { throw MailError.loginRequired }
        try Keychain.save(try JSONEncoder().encode(token), account: key)
        return (email, key)
    }

    public static func tokenKey(forEmail email: String) -> String { "\(defaultTokenKey):\(email.lowercased())" }

    /// 重新授权一个已有账号（比如补上日历权限）；用户在浏览器里选了别的邮箱会报错，token 不会被换掉。
    public func reauthorize(expectedEmail: String) async throws {
        let stored = loadToken()
        let token = try await login(loginHint: expectedEmail, save: false)
        let probe = OAuthClient(config: config, tokenKey: tokenKey)
        probe.cache.token = token
        let email = try await GmailClient(oauth: probe).profile().emailAddress.lowercased()
        guard email == expectedEmail.lowercased() else {
            cache.token = stored
            throw MailError.config("授权的是 \(email)，不是 \(expectedEmail)。请在浏览器里选择 \(expectedEmail)。")
        }
        try saveToken(token)
    }

    func login(loginHint: String? = nil, selectAccount: Bool = false, save: Bool = true) async throws -> StoredToken {
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(bytes: 16)

        let server = try LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: selectAccount ? "select_account consent" : "consent"),
        ]
        if let hint = loginHint ?? ProcessInfo.processInfo.environment["MAIL_LOGIN_HINT"] {
            items.append(URLQueryItem(name: "login_hint", value: hint))
        }
        comps.queryItems = items
        let authURL = comps.url!

        let params = try await server.awaitCallback {
            print("正在打开浏览器登录…\n如果没有自动打开，请手动访问:\n\(authURL.absoluteString)\n")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [authURL.absoluteString]
            try? p.run()
        }

        if let error = params["error"] {
            throw MailError.oauth(code: error, description: params["error_description"])
        }
        guard params["state"] == state, let code = params["code"] else {
            throw MailError.oauth(code: "state_mismatch", description: "回调的 state 不匹配，已拒绝")
        }

        let resp = try await tokenRequest([
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        guard let refreshToken = resp.refresh_token else {
            throw MailError.oauth(code: "no_refresh_token", description: "Google 没有返回 refresh token")
        }
        let token = StoredToken(accessToken: resp.access_token, refreshToken: refreshToken,
                                expiry: Date().addingTimeInterval(TimeInterval(resp.expires_in)),
                                scope: resp.scope ?? Self.scope)
        if save { try saveToken(token) }
        return token
    }

    private func refresh(_ stored: StoredToken) async throws -> StoredToken {
        let resp = try await tokenRequest([
            "refresh_token": stored.refreshToken,
            "grant_type": "refresh_token",
        ])
        let token = StoredToken(accessToken: resp.access_token,
                                refreshToken: resp.refresh_token ?? stored.refreshToken,
                                expiry: Date().addingTimeInterval(TimeInterval(resp.expires_in)),
                                scope: resp.scope ?? stored.scope)
        try saveToken(token)
        return token
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }

    private struct TokenError: Decodable {
        let error: String
        let error_description: String?
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = fields
        form["client_id"] = config.clientID
        form["client_secret"] = config.clientSecret
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        if let err = try? JSONDecoder().decode(TokenError.self, from: data) {
            throw MailError.oauth(code: err.error, description: err.error_description)
        }
        throw MailError.http(status: status, body: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Storage

    func loadToken() -> StoredToken? {
        if let cached = cache.token { return cached }
        guard let data = Keychain.load(account: tokenKey),
              let token = try? JSONDecoder().decode(StoredToken.self, from: data) else { return nil }
        cache.token = token
        return token
    }

    private func saveToken(_ token: StoredToken) throws {
        try Keychain.save(try JSONEncoder().encode(token), account: tokenKey)
        cache.token = token
    }

    public static func logout() { Keychain.delete(account: account) }

    /// 退出登录：删除 Keychain 里的 token，并清掉内存缓存。
    public func signOut() {
        Keychain.delete(account: tokenKey)
        cache.token = nil
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(bytes: Int) -> String {
        base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
