import CryptoKit
import Foundation

struct StoredToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    /// 授权时拿到的范围；旧版本存的 token 没有这个字段（nil 表示只读）
    var scope: String?

    var canModify: Bool { scope?.contains("gmail.modify") ?? false }
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
    /// 标记已读/未读需要 modify；它包含读取权限，所以登录只请求这一个范围
    static let scope = "https://www.googleapis.com/auth/gmail.modify"
    static let account = "gmail-oauth-token"

    let config: ClientConfig
    /// false 时（常驻程序）需要登录会抛 loginRequired，而不是自己弹出浏览器。
    let interactive: Bool
    /// 拷贝共享：避免每个请求都读一次 Keychain
    private let cache = TokenCache()

    public init(config: ClientConfig, interactive: Bool = true) {
        self.config = config
        self.interactive = interactive
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

    /// 主动登录（浏览器授权），常驻程序在 loginRequired 后由用户触发。
    public func signIn() async throws {
        _ = try await login()
    }

    func login() async throws -> StoredToken {
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
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let hint = ProcessInfo.processInfo.environment["MAIL_LOGIN_HINT"] {
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
        try saveToken(token)
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

    private func loadToken() -> StoredToken? {
        if let cached = cache.token { return cached }
        guard let data = Keychain.load(account: Self.account),
              let token = try? JSONDecoder().decode(StoredToken.self, from: data) else { return nil }
        cache.token = token
        return token
    }

    private func saveToken(_ token: StoredToken) throws {
        try Keychain.save(try JSONEncoder().encode(token), account: Self.account)
        cache.token = token
    }

    public static func logout() { Keychain.delete(account: account) }

    /// 退出登录：删除 Keychain 里的 token，并清掉内存缓存。
    public func signOut() {
        Keychain.delete(account: Self.account)
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
