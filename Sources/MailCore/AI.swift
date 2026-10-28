import Foundation
import GRDB

// MARK: - 配置

/// AI 服务的接口协议。绝大多数服务（OpenAI、DeepSeek、OpenRouter、Ollama、LM Studio……）都兼容 OpenAI 格式。
public enum AIProtocol: String, Codable, CaseIterable, Sendable {
    case openai
    case anthropic

    public var title: String {
        switch self {
        case .openai: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }
}

/// 一个 AI 服务（路由目标）。API Key 不在这里，存在钥匙串里（见 AIKeyStore）。
public struct AIProvider: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: AIProtocol
    /// 服务地址：OpenAI 兼容填到 `/v1` 为止（如 https://api.openai.com/v1），Anthropic 填 https://api.anthropic.com
    public var baseURL: String
    public var model: String

    public init(id: String = UUID().uuidString, name: String, kind: AIProtocol, baseURL: String, model: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

    /// 常见服务的预设，设置里一键添加后只需要补 Key。
    public static let presets: [AIProvider] = [
        AIProvider(name: "OpenAI", kind: .openai, baseURL: "https://api.openai.com/v1", model: "gpt-5-mini"),
        AIProvider(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-haiku-5-5"),
        AIProvider(name: "DeepSeek", kind: .openai, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        AIProvider(name: "OpenRouter", kind: .openai, baseURL: "https://openrouter.ai/api/v1", model: "google/gemma-4-e2b-it"),
        AIProvider(name: "本机 Ollama", kind: .openai, baseURL: "http://localhost:11434/v1", model: "gemma4:e2b"),
        AIProvider(name: "本机 LM Studio", kind: .openai, baseURL: "http://localhost:1234/v1", model: "local-model"),
    ]
}

public struct AIConfig: Codable, Equatable, Sendable {
    public var providers: [AIProvider] = []
    public var activeProviderID: String?
    /// 总开关：打开后，没命中提醒规则的新邮件交给 AI 判断要不要通知
    public var notifyEnabled = false
    public var notifyPrompt: String = AINotifyJudge.defaultPrompt
    /// 打开一个 PR / 会话时自动生成 AI 摘要（默认关：每次打开都会调用一次 AI）
    public var autoSummarize = false
    /// 邮件 / PR 摘要的要求
    public var summaryPrompt: String = AIAssistant.defaultSummaryPrompt
    /// 每天固定时间自动生成「今日简报」并通知
    public var briefAuto = false
    public var briefHour = 9
    public var briefMinute = 0
    /// 「需要你处理」的事等了超过这么多小时还没动，提醒一次；0 = 不提醒
    public var followUpHours = 0

    public init() {}

    // 老版本的配置文件没有新增的字段：缺了就用默认值，不能因此把整份配置（含已添加的服务）丢掉
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([AIProvider].self, forKey: .providers) ?? []
        activeProviderID = try c.decodeIfPresent(String.self, forKey: .activeProviderID)
        notifyEnabled = try c.decodeIfPresent(Bool.self, forKey: .notifyEnabled) ?? false
        notifyPrompt = try c.decodeIfPresent(String.self, forKey: .notifyPrompt) ?? AINotifyJudge.defaultPrompt
        autoSummarize = try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? false
        summaryPrompt = try c.decodeIfPresent(String.self, forKey: .summaryPrompt) ?? AIAssistant.defaultSummaryPrompt
        briefAuto = try c.decodeIfPresent(Bool.self, forKey: .briefAuto) ?? false
        briefHour = try c.decodeIfPresent(Int.self, forKey: .briefHour) ?? 9
        briefMinute = try c.decodeIfPresent(Int.self, forKey: .briefMinute) ?? 0
        followUpHours = try c.decodeIfPresent(Int.self, forKey: .followUpHours) ?? 0
    }

    public var active: AIProvider? {
        providers.first { $0.id == activeProviderID } ?? providers.first
    }
}

public enum AIConfigStore {
    public static func defaultPath() -> String {
        if let custom = ProcessInfo.processInfo.environment["MAIL_AI"] { return (custom as NSString).expandingTildeInPath }
        return ("~/Library/Application Support/MailClient/ai.json" as NSString).expandingTildeInPath
    }

    /// 文件不存在或损坏时返回默认配置（全关）。
    public static func read(path: String = defaultPath()) -> AIConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data) else { return AIConfig() }
        return config
    }

    public static func write(_ config: AIConfig, to path: String = defaultPath()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try encoder.encode(config).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// API Key 放钥匙串，不进配置文件。
public enum AIKeyStore {
    private static func account(_ providerID: String) -> String { "ai-key-\(providerID)" }

    public static func key(for providerID: String) -> String {
        Keychain.load(account: account(providerID)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func setKey(_ key: String, for providerID: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: account(providerID)) }
        else { try Keychain.save(Data(trimmed.utf8), account: account(providerID)) }
    }

    public static func deleteKey(for providerID: String) { Keychain.delete(account: account(providerID)) }
}

// MARK: - 调用

public struct AIMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String
    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// 两个方法至少实现一个：单轮的 `complete(system:user:)` 和多轮的 `complete(system:messages:)` 互为默认实现。
public protocol AIChat: Sendable {
    /// 发一轮对话，返回模型的文字回复。
    func complete(system: String, user: String) async throws -> String
    /// 带历史的多轮对话（messages 以 user 开头、user / assistant 交替）。
    func complete(system: String, messages: [AIMessage]) async throws -> String
}

extension AIChat {
    public func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, messages: [AIMessage(.user, user)])
    }

    public func complete(system: String, messages: [AIMessage]) async throws -> String {
        let transcript = messages.map { "\($0.role == .user ? "用户" : "助手")：\($0.content)" }.joined(separator: "\n\n")
        return try await complete(system: system, user: transcript)
    }
}

/// 可替换的网络层，测试里不真正联网。
public typealias AITransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum AITransports {
    public static let live: AITransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MailError.config("AI 服务没有返回 HTTP 响应") }
        return (data, http)
    }
}

public struct AIClient: AIChat {
    let provider: AIProvider
    let apiKey: String
    let transport: AITransport
    let timeout: TimeInterval
    let maxTokens: Int

    public init(provider: AIProvider, apiKey: String, timeout: TimeInterval = 30, maxTokens: Int = 400,
                transport: @escaping AITransport = AITransports.live) {
        self.provider = provider
        self.apiKey = apiKey
        self.timeout = timeout
        self.maxTokens = maxTokens
        self.transport = transport
    }

    public func complete(system: String, messages: [AIMessage]) async throws -> String {
        let request = try makeRequest(system: system, messages: messages)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MailError.http(status: response.statusCode, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        return try parse(data)
    }

    func makeRequest(system: String, user: String) throws -> URLRequest {
        try makeRequest(system: system, messages: [AIMessage(.user, user)])
    }

    func makeRequest(system: String, messages: [AIMessage]) throws -> URLRequest {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw MailError.config("服务地址是空的") }
        guard !provider.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw MailError.config("模型名是空的") }
        let path = provider.kind == .openai ? "/chat/completions" : (base.hasSuffix("/v1") ? "/messages" : "/v1/messages")
        guard let url = URL(string: base + path) else { throw MailError.config("服务地址无效: \(provider.baseURL)") }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch provider.kind {
        case .openai:
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            body = ["model": provider.model, "temperature": 0, "max_tokens": maxTokens,
                    "messages": [["role": "system", "content": system]] + messages.map { ["role": $0.role.rawValue, "content": $0.content] }]
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": provider.model, "max_tokens": maxTokens, "system": system,
                    "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parse(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailError.config("AI 服务返回的不是 JSON")
        }
        switch provider.kind {
        case .openai:
            let choices = root["choices"] as? [[String: Any]]
            if let text = (choices?.first?["message"] as? [String: Any])?["content"] as? String { return text }
        case .anthropic:
            let parts = (root["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
            if let parts, !parts.isEmpty { return parts.joined() }
        }
        throw MailError.config("AI 服务的返回里没有文字内容")
    }
}

// MARK: - 判断新邮件要不要通知

public struct AIVerdict: Equatable, Sendable {
    public let notify: Bool
    public let reason: String
}

public struct AINotifyJudge: Sendable {
    public let chat: any AIChat
    public let prompt: String
    /// 发给 AI 的正文最多多少字，控制费用和隐私暴露面
    public let maxBodyCharacters: Int
    /// 用户的记忆和被纠正过的判断（见 AIContext），拼在 prompt 后面
    public let context: String

    public init(chat: any AIChat, prompt: String, maxBodyCharacters: Int = 1200, context: String = "") {
        self.chat = chat
        self.prompt = prompt
        self.maxBodyCharacters = maxBodyCharacters
        self.context = context
    }

    public func withContext(_ context: String) -> AINotifyJudge {
        AINotifyJudge(chat: chat, prompt: prompt, maxBodyCharacters: maxBodyCharacters, context: context)
    }

    public static let defaultPrompt = """
    你是我的邮件通知过滤器。我是一名程序员，每天收到很多 GitHub、Jira 的通知邮件。
    只有下面这些情况才需要通知我：
    - 有人 @ 了我、请我 review，或者直接问了我问题
    - 我的 PR 被评论、被批准、被要求修改，或者 CI 失败需要我处理
    - 出了线上问题或需要紧急处理的事
    这些情况不需要通知：机器人的例行消息（质量检查通过、体积检查、测试通过）、订阅推送、广告、与我无关的讨论。
    拿不准时，倾向于通知。
    """

    /// 固定的输出约定，拼在用户 prompt 后面，用户改 prompt 不会破坏解析。
    static let outputContract = """

    只回复一行 JSON，不要任何别的文字：{"notify": true 或 false, "reason": "不超过 20 个字的理由"}
    """

    public func judge(subject: String, from: String, source: String, kind: String, body: String) async throws -> AIVerdict {
        let text = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxBodyCharacters))
        let user = """
        来源：\(source)
        类型：\(kind)
        发件人：\(from)
        主题：\(subject)
        正文：
        \(text)
        """
        let reply = try await chat.complete(system: prompt + (context.isEmpty ? "" : "\n\n" + context) + Self.outputContract, user: user)
        guard let verdict = Self.parse(reply) else { throw MailError.config("AI 的回复无法解析: \(reply.prefix(120))") }
        return verdict
    }

    /// 从回复里取出第一个 JSON 对象（兼容 ```json 围栏和前后多余的话）。
    static func parse(_ reply: String) -> AIVerdict? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let notify: Bool
        switch object["notify"] {
        case let value as Bool: notify = value
        case let text as String where ["true", "yes", "是"].contains(text.lowercased()): notify = true
        case let text as String where ["false", "no", "否"].contains(text.lowercased()): notify = false
        default: return nil
        }
        return AIVerdict(notify: notify, reason: (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

// MARK: - 试判定

/// 设置页「试判定」用：本地最近几封邮件，带上判定需要的字段。
public struct AISample: Identifiable, Sendable {
    public let id: String
    public let subject: String
    public let from: String
    public let source: String
    public let kind: String
    public let body: String
}

extension MailStore {
    public func recentAISamples(limit: Int) throws -> [AISample] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, subject, fromAddr, source, kind, bodyText FROM message
                ORDER BY internalDate DESC LIMIT ?
                """, arguments: [limit]).map {
                AISample(id: $0["id"], subject: $0["subject"], from: $0["fromAddr"], source: $0["source"],
                         kind: $0["kind"], body: $0["bodyText"] ?? "")
            }
        }
    }
}
