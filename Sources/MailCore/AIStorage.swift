import Foundation
import GRDB

// MARK: - 待办 / 提醒

public struct Todo: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
    /// 关联的 PR / 会话（ThreadSummary.id）；点它能跳到对应邮件
    public var groupKey: String?
    /// 到点提醒的时间；nil = 只是待办，不提醒
    public var dueAt: Date?
    public var done: Bool
    /// 提醒是否已经发过
    public var notified: Bool
    /// "user"（手动）/ "ai"（来自摘要或对话）
    public var source: String
    public var createdAt: Date

    public var isReminder: Bool { dueAt != nil }
}

public struct AIMemory: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let text: String
}

/// AI 对某封邮件的一次通知判断，以及你的反馈（用来「为什么通知我」和越用越准）。
public struct AIDecision: Identifiable, Equatable, Sendable {
    public var id: String { messageId }
    public let messageId: String
    public let groupKey: String?
    public let subject: String
    public let from: String
    public let source: String
    public let kind: String
    public let notify: Bool
    public let reason: String
    /// 命中的提醒规则（AI 同意通知时沿用规则的名字）
    public let ruleName: String?
    public let createdAt: Date
    /// 1 = 判断对了，-1 = 判断错了，nil = 还没反馈
    public var feedback: Int?
}

// MARK: - 表结构

extension MailStore {
    static func registerAssistantMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14-assistant") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS todo (
                    id TEXT PRIMARY KEY,
                    text TEXT NOT NULL,
                    groupKey TEXT,
                    dueAt REAL,
                    done INTEGER NOT NULL DEFAULT 0,
                    notified INTEGER NOT NULL DEFAULT 0,
                    source TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    doneAt REAL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS todo_open ON todo (done, dueAt)")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS ai_memory (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL UNIQUE,
                    createdAt REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS ai_decision (
                    messageId TEXT PRIMARY KEY,
                    groupKey TEXT,
                    subject TEXT NOT NULL,
                    fromAddr TEXT NOT NULL,
                    source TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    notify INTEGER NOT NULL,
                    reason TEXT NOT NULL,
                    ruleName TEXT,
                    createdAt REAL NOT NULL,
                    feedback INTEGER
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS ai_decision_time ON ai_decision (createdAt DESC)")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS follow_up_nudge (
                    groupKey TEXT NOT NULL,
                    latestMessageId TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    PRIMARY KEY (groupKey, latestMessageId)
                )
                """)
        }
    }

    // MARK: 待办

    private static func todo(_ row: Row) -> Todo {
        Todo(id: row["id"], text: row["text"], groupKey: row["groupKey"],
             dueAt: (row["dueAt"] as Double?).map { Date(timeIntervalSince1970: $0) },
             done: row["done"], notified: row["notified"], source: row["source"],
             createdAt: Date(timeIntervalSince1970: row["createdAt"]))
    }

    /// 加一条待办；同一个关联下已经有同样文字的未完成待办就不重复加，返回已有的那条。
    @discardableResult
    public func addTodo(_ text: String, groupKey: String? = nil, dueAt: Date? = nil, source: String = "user",
                        now: Date = Date()) throws -> Todo {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MailError.config("待办内容是空的") }
        return try db.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM todo WHERE done = 0 AND text = ? AND groupKey IS ?",
                                          arguments: [text, groupKey]) {
                return Self.todo(row)
            }
            let id = UUID().uuidString
            try db.execute(sql: "INSERT INTO todo (id, text, groupKey, dueAt, source, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [id, text, groupKey, dueAt?.timeIntervalSince1970, source, now.timeIntervalSince1970])
            return Todo(id: id, text: text, groupKey: groupKey, dueAt: dueAt, done: false, notified: false, source: source, createdAt: now)
        }
    }

    /// 未完成的在前（有提醒时间的按时间，其余按创建时间新到旧），已完成的在后。
    public func todos(includeDone: Bool = false, limit: Int = 100) throws -> [Todo] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM todo \(includeDone ? "" : "WHERE done = 0")
                ORDER BY done ASC, (dueAt IS NULL) ASC, dueAt ASC, createdAt DESC LIMIT ?
                """, arguments: [limit]).map(Self.todo)
        }
    }

    public func setTodoDone(_ id: String, done: Bool, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE todo SET done = ?, doneAt = ? WHERE id = ?",
                           arguments: [done, done ? now.timeIntervalSince1970 : nil, id])
        }
    }

    public func deleteTodo(_ id: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM todo WHERE id = ?", arguments: [id]) }
    }

    /// 到点、还没完成、还没提醒过的。
    public func dueReminders(now: Date = Date()) throws -> [Todo] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM todo WHERE done = 0 AND notified = 0 AND dueAt IS NOT NULL AND dueAt <= ? ORDER BY dueAt",
                             arguments: [now.timeIntervalSince1970]).map(Self.todo)
        }
    }

    public func markTodoNotified(_ id: String) throws {
        try db.write { try $0.execute(sql: "UPDATE todo SET notified = 1 WHERE id = ?", arguments: [id]) }
    }

    /// 按 id 或 id 前缀（助手看到的是缩短后的）找一条未完成的待办。
    public func openTodo(idPrefix: String) throws -> Todo? {
        let matches = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM todo WHERE done = 0 AND id LIKE ? LIMIT 2", arguments: [idPrefix + "%"]).map(Self.todo)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: 记忆

    public func memories() throws -> [AIMemory] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, text FROM ai_memory ORDER BY id").map { AIMemory(id: $0["id"], text: $0["text"]) }
        }
    }

    public func addMemory(_ text: String, now: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MailError.config("记忆内容是空的") }
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO ai_memory (text, createdAt) VALUES (?, ?)", arguments: [text, now.timeIntervalSince1970])
        }
    }

    public func deleteMemory(_ id: Int64) throws {
        try db.write { try $0.execute(sql: "DELETE FROM ai_memory WHERE id = ?", arguments: [id]) }
    }

    // MARK: AI 判断记录和反馈

    /// 记下一次判断；同一封邮件重复判断时保留已有的反馈。
    public func recordDecision(messageId: String, groupKey: String?, subject: String, from: String, source: String, kind: String,
                               notify: Bool, reason: String, ruleName: String?, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO ai_decision (messageId, groupKey, subject, fromAddr, source, kind, notify, reason, ruleName, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(messageId) DO UPDATE SET notify = excluded.notify, reason = excluded.reason, ruleName = excluded.ruleName,
                                                     createdAt = excluded.createdAt
                """, arguments: [messageId, groupKey, subject, from, source, kind, notify, reason, ruleName, now.timeIntervalSince1970])
        }
    }

    private static func decision(_ row: Row) -> AIDecision {
        AIDecision(messageId: row["messageId"], groupKey: row["groupKey"], subject: row["subject"], from: row["fromAddr"],
                   source: row["source"], kind: row["kind"], notify: row["notify"], reason: row["reason"], ruleName: row["ruleName"],
                   createdAt: Date(timeIntervalSince1970: row["createdAt"]), feedback: row["feedback"])
    }

    public func recentDecisions(limit: Int = 30) throws -> [AIDecision] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_decision ORDER BY createdAt DESC LIMIT ?", arguments: [limit]).map(Self.decision)
        }
    }

    /// value：1 判断对了，-1 判断错了，nil 清除反馈。
    public func setFeedback(messageId: String, value: Int?) throws {
        try db.write { try $0.execute(sql: "UPDATE ai_decision SET feedback = ? WHERE messageId = ?", arguments: [value, messageId]) }
    }

    /// 用户纠正过的判断（判错的），最近的在前：喂给判断 prompt 当例子。
    public func correctedDecisions(limit: Int = 8) throws -> [AIDecision] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_decision WHERE feedback = -1 ORDER BY createdAt DESC LIMIT ?", arguments: [limit]).map(Self.decision)
        }
    }

    // MARK: 跟进提醒

    func wasNudged(group: String, latestMessageId: String) throws -> Bool {
        try db.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM follow_up_nudge WHERE groupKey = ? AND latestMessageId = ?)",
                              arguments: [group, latestMessageId]) ?? false
        }
    }

    func markNudged(group: String, latestMessageId: String, now: Date) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO follow_up_nudge (groupKey, latestMessageId, createdAt) VALUES (?, ?, ?)",
                           arguments: [group, latestMessageId, now.timeIntervalSince1970])
        }
    }
}

// MARK: - 给 AI 的背景（记忆 + 被纠正过的判断）

public enum AIContext {
    /// 拼进系统提示的背景文字；没有记忆也没有纠正时返回空串。
    public static func build(store: MailStore) -> String {
        var parts: [String] = []
        if let memories = try? store.memories(), !memories.isEmpty {
            parts.append("【用户的偏好和需要记住的事】\n" + memories.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if let corrected = try? store.correctedDecisions(), !corrected.isEmpty {
            let lines = corrected.map { decision in
                "- 邮件「\(decision.subject.prefix(80))」（发件人 \(decision.from.prefix(40))）：你曾判断为\(decision.notify ? "通知" : "不通知")，用户说判错了，应该\(decision.notify ? "不通知" : "通知")"
            }
            parts.append("【用户纠正过的判断，类似的邮件请照用户的意思处理】\n" + lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - 跟进：等你太久的事

public enum FollowUps {
    /// 「需要你处理」的 PR / 会话里，最近一次动静已经过去 olderThan 秒、仍然没处理（还是未读）的。
    /// 同一个分组的同一封最新邮件只提醒一次：返回的同时记下，之后有新邮件才会再提醒。
    public static func collect(store: MailStore, now: Date = Date(), olderThan: TimeInterval) throws -> [ThreadSummary] {
        let cutoff = now.addingTimeInterval(-olderThan)
        let candidates = try store.threads(in: .attention, groupByPR: true, limit: 50)
            .filter { $0.isUnread && $0.date <= cutoff }
        var due: [ThreadSummary] = []
        for thread in candidates where !(try store.wasNudged(group: thread.id, latestMessageId: thread.latestMessageId)) {
            try store.markNudged(group: thread.id, latestMessageId: thread.latestMessageId, now: now)
            due.append(thread)
        }
        return due
    }
}

// MARK: - 时间解析（助手给出的提醒时间）

public enum AIDate {
    /// 支持：`2026-10-28 09:00`、`2026-10-28T09:00[:00]`、`09:00`（今天，已过则明天）、`+30m` / `+2h` / `+1d`。按本地时区。
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("+"), let unit = s.last, let n = Double(s.dropFirst().dropLast()), n > 0 {
            switch unit {
            case "m": return now.addingTimeInterval(n * 60)
            case "h": return now.addingTimeInterval(n * 3600)
            case "d": return now.addingTimeInterval(n * 86400)
            default: return nil
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: s) { return date }
        }
        formatter.dateFormat = "HH:mm"
        if let time = formatter.date(from: s) {
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            guard let today = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) else { return nil }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        return nil
    }
}
