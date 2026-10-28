import Foundation
import GRDB

// MARK: - 我是谁

/// 让 AI 知道「我」是谁：GitHub 用户名和 Jira 显示名，用来判断"有没有人@我""这个待办是不是我的"。
public struct AIProfile: Sendable, Equatable {
    public var githubLogin: String
    public var jiraName: String

    public init(githubLogin: String = "", jiraName: String = "") {
        self.githubLogin = githubLogin
        self.jiraName = jiraName
    }

    var text: String {
        var parts: [String] = []
        if !githubLogin.isEmpty { parts.append("GitHub 用户名 \(githubLogin)") }
        if !jiraName.isEmpty { parts.append("Jira 显示名 \(jiraName)") }
        return parts.isEmpty ? "（用户没有填写自己的账号名）" : "用户的账号：" + parts.joined(separator: "，")
    }
}

// MARK: - 线程摘要

public struct AIThreadSummary: Codable, Equatable, Sendable {
    /// 2–3 句话讲清楚发生了什么
    public var summary: String
    /// 一句话：当前进展 / 卡在哪
    public var status: String
    /// 需要用户本人去做的事
    public var todos: [String]

    public init(summary: String, status: String, todos: [String]) {
        self.summary = summary
        self.status = status
        self.todos = todos
    }
}

/// 把一个会话 / PR 里的邮件整理成给 AI 读的文字：跳过例行机器人，去掉引用，限制总长度（保留最新的）。
enum AITranscript {
    /// includeRoutine 为 true 时例行机器人消息也带上，但每条只留一行（「全部内容」用于邮件摘要）。
    static func make(_ messages: [MessageDetail], budget: Int = 12_000, perMessage: Int = 1_200, includeRoutine: Bool = false) -> String {
        let routine = includeRoutine ? 0 : messages.filter { $0.kind == MessageKind.botRoutine.rawValue }.count
        var blocks: [String] = []
        for message in messages {
            let header = "[\(DateText.full(message.date))] \(message.from)（\(label(message.kind))）"
            if message.kind == MessageKind.botRoutine.rawValue {
                guard includeRoutine else { continue }
                blocks.append("\(header) \(clean(message.bodyText, limit: 160).split(separator: "\n").first.map(String.init) ?? message.snippet)")
            } else {
                blocks.append("\(header)\n\(clean(message.bodyText.isEmpty ? message.snippet : message.bodyText, limit: perMessage))")
            }
        }
        var kept: [String] = []
        var used = 0
        for block in blocks.reversed() {
            if used + block.count > budget, !kept.isEmpty { break }
            kept.append(block)
            used += block.count
        }
        var text = kept.reversed().joined(separator: "\n\n")
        if kept.count < blocks.count { text = "（更早的 \(blocks.count - kept.count) 封邮件已省略）\n\n" + text }
        if routine > 0 { text += "\n\n（另有 \(routine) 条例行机器人消息已省略）" }
        return text
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case MessageKind.human.rawValue: return "真人"
        case MessageKind.botAlert.rawValue: return "机器人·出问题"
        case MessageKind.botRoutine.rawValue: return "例行机器人"
        default: return "机器人"
        }
    }

    static func clean(_ body: String, limit: Int) -> String {
        let lines = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
        return String(lines.joined(separator: "\n").prefix(limit))
    }
}

// MARK: - 工具（助手查邮件用）

public protocol AIMailTools: Sendable {
    /// 工具说明，写进系统提示
    var documentation: String { get }
    func run(tool: String, arguments: [String: String]) throws -> String
}

/// 基于本地邮件库的工具：搜索、看某个 PR / 会话、未读、最近动态、需要我处理的。
public struct StoreMailTools: AIMailTools {
    let store: MailStore
    let now: @Sendable () -> Date

    public init(store: MailStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public let documentation = """
    - search：按关键词搜索邮件（主题、发件人、正文）。参数 query。
    - thread：看某个 PR 或会话里的邮件内容。参数 id（用其他工具结果里方括号里的编号，如 owner/repo#123）。
    - unread：当前未读的 PR / 会话列表。参数 limit（默认 20）。
    - need_me：需要我处理的（出问题的，或和我相关的 PR 上有真人的新评论）。
    - recent：最近一段时间有动静的 PR / 会话。参数 hours（默认 24）。
    - todos：我现在的待办和提醒（带编号）。
    - add_todo：加一条待办。参数 text，可选 group（相关的 PR 编号）。用户让你「记一下」「加个待办」时用。
    - remind：设一个到点提醒。参数 text、when，可选 group。when 写成 `YYYY-MM-DD HH:mm`（本地时间），或 `+30m` / `+2h` / `+1d`（多久以后）。
    - done_todo：把待办标为完成。参数 id（todos 里给的编号）。
    - remember：记住用户的一条长期偏好或事实（如「Dependabot 的 PR 不用通知我」）。参数 text。只在用户明确要你记住时用。
    """

    public func run(tool: String, arguments: [String: String]) throws -> String {
        switch tool {
        case "search":
            let query = arguments["query"] ?? ""
            guard !query.isEmpty else { return "缺少参数 query" }
            let found = try store.search(query, limit: 10)
            if found.isEmpty { return "没有找到包含「\(query)」的邮件" }
            return try found.map { message in
                let key = try store.prKey(forThread: message.threadId) ?? message.threadId
                return "[\(key)] \(DateText.full(message.date)) \(message.from) — \(message.subject)\(message.isUnread ? " （未读）" : "")"
            }.joined(separator: "\n")
        case "thread":
            guard let id = arguments["id"], !id.isEmpty else { return "缺少参数 id" }
            let messages = try store.messages(inGroup: id)
            if messages.isEmpty { return "没有找到 \(id)" }
            return "# \(messages.last?.subject ?? id)\n" + AITranscript.make(messages, budget: 8_000)
        case "unread":
            let limit = Int(arguments["limit"] ?? "") ?? 20
            return lines(try store.threads(in: .unread, groupByPR: true, limit: max(1, min(limit, 40))), empty: "没有未读邮件")
        case "need_me":
            return lines(try store.threads(in: .attention, groupByPR: true, limit: 20), empty: "目前没有需要你处理的邮件")
        case "recent":
            let hours = Double(arguments["hours"] ?? "") ?? 24
            let since = now().addingTimeInterval(-hours * 3600)
            let threads = try store.threads(in: .allMail, groupByPR: true, limit: 60).filter { $0.date >= since }
            return lines(Array(threads.prefix(30)), empty: "最近 \(Int(hours)) 小时没有动静")
        case "todos":
            let todos = try store.todos(limit: 30)
            if todos.isEmpty { return "目前没有待办" }
            return todos.map { todo in
                var parts = ["(\(todo.id.prefix(8))) \(todo.text)"]
                if let due = todo.dueAt { parts.append("提醒 \(DateText.full(due))") }
                if let group = todo.groupKey { parts.append("相关 [\(group)]") }
                return parts.joined(separator: " · ")
            }.joined(separator: "\n")
        case "add_todo":
            guard let text = arguments["text"], !text.isEmpty else { return "缺少参数 text" }
            let todo = try store.addTodo(text, groupKey: arguments["group"].flatMap { $0.isEmpty ? nil : $0 }, source: "ai", now: now())
            return "已加入待办：\(todo.text)"
        case "remind":
            guard let text = arguments["text"], !text.isEmpty else { return "缺少参数 text" }
            guard let when = arguments["when"], let due = AIDate.parse(when, now: now()) else {
                return "when 无法识别，请用 YYYY-MM-DD HH:mm 或 +30m / +2h / +1d"
            }
            guard due > now() else { return "提醒时间已经过去了，请给一个将来的时间" }
            let todo = try store.addTodo(text, groupKey: arguments["group"].flatMap { $0.isEmpty ? nil : $0 }, dueAt: due, source: "ai", now: now())
            return "已设置提醒：\(DateText.full(due)) \(todo.text)"
        case "done_todo":
            guard let id = arguments["id"], !id.isEmpty else { return "缺少参数 id" }
            guard let todo = try store.openTodo(idPrefix: id) else { return "没有找到编号为 \(id) 的未完成待办" }
            try store.setTodoDone(todo.id, done: true, now: now())
            return "已完成：\(todo.text)"
        case "remember":
            guard let text = arguments["text"], !text.isEmpty else { return "缺少参数 text" }
            try store.addMemory(text, now: now())
            return "已记住：\(text)"
        default:
            return "没有这个工具：\(tool)"
        }
    }

    func lines(_ threads: [ThreadSummary], empty: String) -> String {
        if threads.isEmpty { return empty }
        return threads.map(Self.line).joined(separator: "\n")
    }

    static func line(_ t: ThreadSummary) -> String {
        var parts = ["[\(t.id)] \(t.prSubject ?? t.subject)", t.source]
        if t.unreadCount > 0 {
            parts.append("未读 \(t.unreadCount)（真人 \(t.humanUnread) / 出问题 \(t.alertUnread) / 例行 \(t.routineUnread)）")
        }
        if let from = t.lastHumanFrom { parts.append("最近真人：\(from)") }
        if !t.reasons.isEmpty { parts.append("我的关系：\(t.reasons.joined(separator: "、"))") }
        if t.ciFailures > 0 { parts.append("CI 失败 \(t.ciFailures) 次") }
        parts.append(DateText.full(t.date))
        return parts.joined(separator: " · ")
    }
}

// MARK: - 助手

public struct AIAnswer: Equatable, Sendable {
    public let text: String
    /// 助手回答前查了哪些东西，界面上显示成"查了 xxx"
    public let steps: [String]
}

public struct AIAssistant: Sendable {
    public let chat: any AIChat
    public let profile: AIProfile
    /// 用户的记忆和被纠正过的判断（见 AIContext），拼进系统提示
    public let context: String
    let now: @Sendable () -> Date

    public init(chat: any AIChat, profile: AIProfile, context: String = "", now: @escaping @Sendable () -> Date = Date.init) {
        self.chat = chat
        self.profile = profile
        self.context = context
        self.now = now
    }

    private var preamble: String {
        let base = "你是用户的个人邮件助手。用户是程序员，邮箱里主要是 GitHub、Jira 的通知邮件。\(profile.text)。现在是 \(DateText.full(now()))。用简体中文回答，简洁、具体，不要编造邮件里没有的信息。"
        return context.isEmpty ? base : base + "\n\n" + context
    }

    // MARK: 线程摘要

    /// 默认的摘要要求（设置 → AI 里可以改）。输出格式由程序另外追加，改 prompt 不会弄坏解析。
    public static let defaultSummaryPrompt = """
    下面是一封邮件，或一个 PR / 会话的全部往来内容（按时间顺序）。请帮我总结：
    - summary：讲清楚这件事是什么、发生了什么、讨论的结论；内容多时可以分几条，用 Markdown 列表
    - status：一句话说当前进展，或者卡在哪里
    - todos：确实需要我本人去做的事（被请求 review、被问了问题、CI 失败需要处理、被要求修改等），没有就给空数组
    机器人的例行消息（质量检查通过、测试汇总等）一般不用提，除非它们说明了问题。
    """

    static let summaryContract = """

    只回复一个 JSON 对象，不要任何别的文字：{"summary": "……", "status": "……", "todos": ["……"]}
    """

    /// 总结一封邮件或一个 PR / 会话。AI 看到的是全部邮件（例行机器人消息压成一行），太长时保留最新的。
    public func summarize(title: String, messages: [MessageDetail], prompt: String = AIAssistant.defaultSummaryPrompt) async throws -> AIThreadSummary {
        let system = "\(preamble)\n\(prompt)\(Self.summaryContract)"
        let user = "标题：\(title)\n\n\(AITranscript.make(messages, budget: 60_000, perMessage: 6_000, includeRoutine: true))"
        let reply = try await chat.complete(system: system, user: user)
        guard let summary = Self.decode(AIThreadSummary.self, from: reply) else {
            throw MailError.config("AI 的回复无法解析: \(reply.prefix(120))")
        }
        return summary
    }

    // MARK: 每日简报

    public func brief(tools: AIMailTools) async throws -> String {
        let needMe = try tools.run(tool: "need_me", arguments: [:])
        let unread = try tools.run(tool: "unread", arguments: ["limit": "25"])
        let recent = try tools.run(tool: "recent", arguments: ["hours": "18"])
        let todos = try tools.run(tool: "todos", arguments: [:])
        let system = """
        \(preamble)
        请根据下面的数据写一份简报，用 Markdown，分成几段，没有内容的段落直接省略：
        ## 待办与提醒
        用户自己记下的待办和即将到点的提醒，每条一行（只在有待办时写）。
        ## 需要你处理
        每条一行：`[编号]` 标题 — 为什么需要你、该做什么。按紧急程度排序。
        ## 值得关注的进展
        和用户相关的 PR / 讨论的重要变化，每条一行。
        ## 可以忽略
        一句话概括例行消息的情况（如多少个 PR 只有机器人在更新）。
        开头先用一句话总结今天的整体情况。不要罗列没有信息量的东西。
        """
        let user = "【我的待办】\n\(todos)\n\n【需要我处理的】\n\(needMe)\n\n【未读】\n\(unread)\n\n【最近 18 小时有动静的】\n\(recent)"
        return try await chat.complete(system: system, user: user).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 对话

    /// 回答一个问题：模型可以多次调用工具查邮件，直到给出最终回答。
    /// 工具调用约定：回复一个 JSON `{"tool": "名字", "args": {...}}`；不是这种 JSON 的回复就是最终回答。
    public func ask(_ history: [AIMessage], tools: AIMailTools, maxSteps: Int = 5) async throws -> AIAnswer {
        let system = """
        \(preamble)
        你可以查用户的本地邮件库来回答问题。要用工具时，只回复一个 JSON，不要别的文字：{"tool": "工具名", "args": {"参数名": "值"}}
        工具：
        \(tools.documentation)
        拿到工具结果后可以继续调用工具，信息够了就直接用自然语言回答。回答里提到 PR 或会话时带上它的编号（方括号里的）。查不到就如实说查不到。
        """
        var messages = history
        var steps: [String] = []
        for step in 0...maxSteps {
            let forceAnswer = step == maxSteps
            if forceAnswer { messages.append(AIMessage(.user, "请基于已经查到的信息直接回答，不要再调用工具。")) }
            let reply = try await chat.complete(system: system, messages: messages)
            guard !forceAnswer, let call = Self.toolCall(in: reply) else {
                return AIAnswer(text: reply.trimmingCharacters(in: .whitespacesAndNewlines), steps: steps)
            }
            steps.append(Self.describe(call))
            let result: String
            do { result = try tools.run(tool: call.tool, arguments: call.arguments) } catch { result = "工具出错：\(error.localizedDescription)" }
            messages.append(AIMessage(.assistant, reply))
            messages.append(AIMessage(.user, "工具结果：\n\(result.prefix(6_000))"))
        }
        return AIAnswer(text: "", steps: steps)
    }

    struct ToolCall: Equatable {
        let tool: String
        let arguments: [String: String]
    }

    static func toolCall(in reply: String) -> ToolCall? {
        guard let object = jsonObject(in: reply), let tool = object["tool"] as? String else { return nil }
        var arguments: [String: String] = [:]
        for (key, value) in (object["args"] as? [String: Any]) ?? [:] {
            if let text = value as? String { arguments[key] = text }
            else if let number = value as? NSNumber { arguments[key] = number.stringValue }
        }
        return ToolCall(tool: tool, arguments: arguments)
    }

    static func describe(_ call: ToolCall) -> String {
        let detail = call.arguments["query"] ?? call.arguments["text"] ?? call.arguments["id"] ?? call.arguments["hours"].map { "\($0) 小时" } ?? ""
        let name: String
        switch call.tool {
        case "search": name = "搜索"
        case "thread": name = "查看"
        case "unread": name = "未读列表"
        case "need_me": name = "需要处理的"
        case "recent": name = "最近动态"
        case "todos": name = "待办列表"
        case "add_todo": name = "加入待办"
        case "remind": name = "设置提醒"
        case "done_todo": name = "完成待办"
        case "remember": name = "记住"
        default: name = call.tool
        }
        return detail.isEmpty ? name : "\(name) \(detail)"
    }

    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - 摘要缓存

extension MailStore {
    /// 取缓存的摘要；最新一封邮件变了（来了新邮件）就当没有。
    public func aiSummary(group: String, latestMessageId: String) throws -> AIThreadSummary? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT latestMessageId, json FROM ai_summary WHERE groupKey = ?", arguments: [group]),
                  (row["latestMessageId"] as String) == latestMessageId,
                  let data = (row["json"] as String).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AIThreadSummary.self, from: data)
        }
    }

    public func saveAISummary(_ summary: AIThreadSummary, group: String, latestMessageId: String) throws {
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO ai_summary (groupKey, latestMessageId, json, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [group, latestMessageId, json, Date().timeIntervalSince1970])
        }
    }
}

// MARK: - 报告里的邮件链接

/// 把 AI 回答里的 PR 编号（`[owner/repo#123]`、带反引号的、或直接写出来的）和会话 id 换成 Markdown 链接，
/// 界面里点击即可跳到对应的邮件。链接用应用自己的 `mailbar://thread?id=…` 地址。
public enum AILinks {
    public static let scheme = "mailbar"

    public static func url(for key: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "thread"
        components.queryItems = [URLQueryItem(name: "id", value: key)]
        return components.url
    }

    /// `mailbar://thread?id=…` 里的分组 key；不是这种链接返回 nil。
    public static func key(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "thread",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { return nil }
        return id
    }

    private static let prKey = #"[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+#\d+"#
    // 已经是 Markdown 链接 `[文字](地址)` 的不再处理；其余按 PR 编号（可带方括号 / 反引号）或方括号里的会话 id 匹配
    private static let pattern = try! NSRegularExpression(
        pattern: #"\[[^\]]*\]\([^)]*\)|`?\[?(\#(prKey))\]?`?|`?\[([0-9a-f]{14,})\]`?"#)

    public static func linkify(_ text: String) -> String {
        var result = text
        let full = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: full).reversed() {
            let keyRange = [1, 2].map { match.range(at: $0) }.first { $0.location != NSNotFound }
            guard let keyRange, let key = Range(keyRange, in: text), let whole = Range(match.range, in: text),
                  let link = url(for: String(text[key])) else { continue }
            result.replaceSubrange(whole, with: "[\(text[key])](\(link.absoluteString))")
        }
        return result
    }

    private static let linkTarget = try! NSRegularExpression(pattern: #"mailbar://thread\?id=([^)\s]+)"#)

    /// 文字里出现的链接目标，按出现顺序去重。
    public static func keys(in text: String) -> [String] {
        var seen = Set<String>()
        return linkTarget.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            let raw = String(text[r])
            let key = raw.removingPercentEncoding ?? raw
            return seen.insert(key).inserted ? key : nil
        }
    }
}
