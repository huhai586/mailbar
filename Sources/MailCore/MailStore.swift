import Foundation
import GRDB

public struct MessageSummary: Equatable, Sendable {
    public let id: String
    public let threadId: String
    public let subject: String
    public let from: String
    public let date: Date
    public let snippet: String
    public let isUnread: Bool
}

public final class MailStore: @unchecked Sendable {
    let db: any DatabaseWriter

    /// path 为 nil 时使用内存数据库（测试用）。
    public init(path: String?) throws {
        if let path {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            db = try DatabasePool(path: path)
        } else {
            db = try DatabaseQueue()
        }
        try Self.migrator.migrate(db)
    }

    public static func defaultPath() -> String {
        if let custom = ProcessInfo.processInfo.environment["MAIL_DB"] { return (custom as NSString).expandingTildeInPath }
        return ("~/Library/Application Support/MailClient/mail.sqlite" as NSString).expandingTildeInPath
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);

                CREATE TABLE label (id TEXT PRIMARY KEY, name TEXT NOT NULL, type TEXT);

                CREATE TABLE message (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    threadId TEXT NOT NULL,
                    historyId TEXT,
                    internalDate INTEGER NOT NULL,
                    subject TEXT NOT NULL,
                    fromAddr TEXT NOT NULL,
                    toAddr TEXT NOT NULL,
                    snippet TEXT NOT NULL,
                    bodyText TEXT NOT NULL,
                    bodyHtml TEXT,
                    isUnread INTEGER NOT NULL,
                    hasAttachments INTEGER NOT NULL,
                    sizeEstimate INTEGER
                );
                CREATE INDEX message_date ON message(internalDate DESC);
                CREATE INDEX message_thread ON message(threadId);

                CREATE TABLE message_label (
                    messageId TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    labelId TEXT NOT NULL,
                    PRIMARY KEY (messageId, labelId)
                );
                CREATE INDEX message_label_label ON message_label(labelId);

                -- trigram 支持任意子串匹配（含中文，但查询词需 ≥ 3 个字符）；rowid 对应 message.seq
                CREATE VIRTUAL TABLE message_fts USING fts5(subject, fromAddr, bodyText, tokenize = 'trigram');
                """)
        }
        migrator.registerMigration("v2-rule-match") { db in
            try db.execute(sql: """
                CREATE TABLE rule_match (
                    messageId TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    ruleName TEXT NOT NULL,
                    matchedAt INTEGER NOT NULL,
                    PRIMARY KEY (messageId, ruleName)
                );
                CREATE INDEX rule_match_rule ON rule_match(ruleName);
                """)
        }
        migrator.registerMigration("v3-reason") { db in
            // NULL = 还没确认；'' = 确认过，没有 X-GitHub-Reason
            try db.execute(sql: "ALTER TABLE message ADD COLUMN reason TEXT")
        }
        migrator.registerMigration("v4-pr-key") { db in
            try db.execute(sql: "ALTER TABLE message ADD COLUMN prKey TEXT; CREATE INDEX message_prkey ON message(prKey);")
            // 给已有的邮件回填：主题里的 (PR #n) 或正文里的 PR 链接
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, substr(bodyText, 1, 6000) AS body FROM message") {
                if let key = GitHubSubject.prKey(subject: row["subject"], body: row["body"]) {
                    try db.execute(sql: "UPDATE message SET prKey = ? WHERE id = ?", arguments: [key, row["id"] as String])
                }
            }
            try MailStore.resolveCIKeys(db)
        }
        migrator.registerMigration("v5-source") { db in
            try db.execute(sql: """
                ALTER TABLE message ADD COLUMN source TEXT NOT NULL DEFAULT 'other';
                ALTER TABLE message ADD COLUMN kind TEXT NOT NULL DEFAULT 'human';
                CREATE INDEX message_source ON message(source);
                CREATE INDEX message_kind ON message(kind);
                """)
            // 给已有的邮件回填来源和类型
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, fromAddr, reason, snippet, substr(bodyText, 1, 2500) AS body FROM message") {
                let source = NotificationClassifier.classify(subject: row["subject"], from: row["fromAddr"], reason: row["reason"], body: row["snippet"])?
                    .service.rawValue ?? "other"
                let kind = MessageClassifier.kind(subject: row["subject"], from: row["fromAddr"], body: row["body"]).rawValue
                try db.execute(sql: "UPDATE message SET source = ?, kind = ? WHERE id = ?", arguments: [source, kind, row["id"] as String])
            }
        }
        migrator.registerMigration("v6-push") { db in
            // 新增 push 类型：把已有的"X pushed N commits"从 human 改过来
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, fromAddr, substr(bodyText, 1, 2500) AS body FROM message WHERE kind = 'human'") {
                let kind = MessageClassifier.kind(subject: row["subject"], from: row["fromAddr"], body: row["body"])
                if kind == .push { try db.execute(sql: "UPDATE message SET kind = 'push' WHERE id = ?", arguments: [row["id"] as String]) }
            }
        }
        migrator.registerMigration("v7-reclassify") { db in
            // 机器人识别收紧了（只认标题里的模板名），重新判定所有邮件的类型
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, fromAddr, substr(bodyText, 1, 2500) AS body FROM message") {
                let kind = MessageClassifier.kind(subject: row["subject"], from: row["fromAddr"], body: row["body"]).rawValue
                try db.execute(sql: "UPDATE message SET kind = ? WHERE id = ?", arguments: [kind, row["id"] as String])
            }
        }
        migrator.registerMigration("v8-reclassify") { db in
            // 机器人识别又调整了（兼容 CRLF、QA 平台报告），重新判定所有邮件的类型
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, fromAddr, substr(bodyText, 1, 2500) AS body FROM message") {
                let kind = MessageClassifier.kind(subject: row["subject"], from: row["fromAddr"], body: row["body"]).rawValue
                try db.execute(sql: "UPDATE message SET kind = ? WHERE id = ?", arguments: [kind, row["id"] as String])
            }
        }
        migrator.registerMigration("v9-mention-rematch") { db in
            // "提及"不再算机器人邮件：让规则命中记录重新计算
            try db.execute(sql: "DELETE FROM sync_state WHERE key = 'rulesFingerprint'")
        }
        migrator.registerMigration("v10-reclassify-summary") { db in
            // "Tests Summary / Test Report" 的识别放宽了（带 s 的复数写法），重新判定类型；规则命中也重新计算
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, fromAddr, substr(bodyText, 1, 2500) AS body FROM message") {
                let kind = MessageClassifier.kind(subject: row["subject"], from: row["fromAddr"], body: row["body"]).rawValue
                try db.execute(sql: "UPDATE message SET kind = ? WHERE id = ?", arguments: [kind, row["id"] as String])
            }
            try db.execute(sql: "DELETE FROM sync_state WHERE key = 'rulesFingerprint'")
        }
        migrator.registerMigration("v11-reclassify-upgraded-defaults") { db in
            // 本机保存的识别配置里还是旧的默认值（v10 当时读到的就是旧的），升级成新默认后再判定一次
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, fromAddr, substr(bodyText, 1, 2500) AS body FROM message") {
                let kind = MessageClassifier.kind(subject: row["subject"], from: row["fromAddr"], body: row["body"]).rawValue
                try db.execute(sql: "UPDATE message SET kind = ? WHERE id = ?", arguments: [kind, row["id"] as String])
            }
            try db.execute(sql: "DELETE FROM sync_state WHERE key = 'rulesFingerprint'")
        }
        migrator.registerMigration("v12-group-key-index") { db in
            // 列表里每一行都要按"分组键"（PR 或会话）回查同组邮件：没有这个表达式索引时是整表扫描，
            // 邮件一多（尤其是结果行很多的「其他」）切换邮箱就卡
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS message_group_key ON message (COALESCE(prKey, threadId), kind, internalDate)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS rule_match_rule ON rule_match (ruleName, messageId)")
        }
        migrator.registerMigration("v13-ai-summary") { db in
            // AI 线程摘要缓存：按分组（PR 或会话）存一份，最新一封邮件变了就算过期
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS ai_summary (
                    groupKey TEXT PRIMARY KEY,
                    latestMessageId TEXT NOT NULL,
                    json TEXT NOT NULL,
                    createdAt REAL NOT NULL
                )
                """)
        }
        registerAssistantMigrations(&migrator)
        registerPendingMigrations(&migrator)
        return migrator
    }

    /// CI 失败通知（`PR run failed: <工作流> - <PR 标题>`）没有 PR 编号，按"仓库 + 标题"对上同一个 PR 的其他邮件。
    static func resolveCIKeys(_ db: Database) throws {
        let pending = try Row.fetchAll(db, sql: "SELECT id, subject FROM message WHERE prKey IS NULL AND subject LIKE '%PR run failed:%'")
        guard !pending.isEmpty else { return }
        var byTitle: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT subject, prKey FROM message WHERE prKey IS NOT NULL AND subject LIKE '%[%/%]%'") {
            guard let github = GitHubSubject.parse(row["subject"]) else { continue }
            byTitle["\(github.repo)|\(GitHubSubject.normalizedTitle(github.title))"] = row["prKey"]
        }
        for row in pending {
            guard let ci = GitHubSubject.parseCIRun(row["subject"]),
                  let key = byTitle["\(ci.repo)|\(GitHubSubject.normalizedTitle(ci.prTitle))"] else { continue }
            try db.execute(sql: "UPDATE message SET prKey = ? WHERE id = ?", arguments: [key, row["id"] as String])
        }
    }

    /// 重新把没有编号的 CI 失败邮件对上它们的 PR。入库时会自动做；这里给"重新匹配"和升级后的老数据用。
    public func relinkPRs() throws {
        try db.write { try Self.resolveCIKeys($0) }
    }

    // MARK: - Rule matches

    /// 记录一次命中；返回 true 表示这是第一次命中（用来做提醒去重）。
    func recordMatch(messageId: String, ruleName: String) throws -> Bool {
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO rule_match(messageId, ruleName, matchedAt) VALUES (?, ?, ?)",
                           arguments: [messageId, ruleName, Int64(Date().timeIntervalSince1970 * 1000)])
            return db.changesCount > 0
        }
    }

    func clearMatches() throws {
        try db.write { try $0.execute(sql: "DELETE FROM rule_match") }
    }

    /// 分页读取全部邮件的匹配内容，供规则变更后重新匹配。
    func matchables(afterSeq: Int64, limit: Int) throws -> [(seq: Int64, id: String, matchable: Matchable)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT seq, id, subject, fromAddr, toAddr, bodyText, COALESCE(reason, '') AS reason, kind FROM message WHERE seq > ? ORDER BY seq LIMIT ?",
                             arguments: [afterSeq, limit]).map { row in
                (row["seq"], row["id"], Matchable(subject: row["subject"], from: row["fromAddr"], to: row["toAddr"], body: row["bodyText"],
                          reason: GitHubReason.effective(reason: row["reason"], kind: MessageKind(rawValue: row["kind"]) ?? .human)))
            }
        }
    }

    public func matchCounts() throws -> [(name: String, count: Int)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT ruleName, COUNT(*) AS n FROM rule_match GROUP BY ruleName ORDER BY ruleName")
                .map { (name: $0["ruleName"], count: $0["n"]) }
        }
    }

    /// 每条规则命中的"未读分组"数（按 PR 聚合：同一个 PR 算一个）。侧栏的数字用它：看过就减少，没有未读就不显示。
    public func unreadMatchCounts() throws -> [(name: String, count: Int)] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.ruleName AS ruleName, COUNT(DISTINCT COALESCE(m.prKey, m.threadId)) AS n
                FROM rule_match r JOIN message m ON m.id = r.messageId
                WHERE m.isUnread = 1 GROUP BY r.ruleName ORDER BY r.ruleName
                """).map { (name: $0["ruleName"], count: $0["n"]) }
        }
    }

    /// 命中某条规则（rule 为 nil 则任意规则）的邮件，最新的在前。
    public func matches(rule: String?, limit: Int) throws -> [MessageSummary] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM message
                WHERE id IN (SELECT messageId FROM rule_match WHERE ?1 IS NULL OR ruleName = ?1)
                ORDER BY internalDate DESC LIMIT ?2
                """, arguments: [rule, limit])
            return rows.map(Self.summary)
        }
    }

    // MARK: - Sync state

    func state(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]) }
    }

    func setState(_ pairs: [String: String]) throws {
        try db.write { db in
            for (key, value) in pairs {
                try db.execute(sql: "INSERT OR REPLACE INTO sync_state(key, value) VALUES (?, ?)", arguments: [key, value])
            }
        }
    }

    func removeState(_ key: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [key]) }
    }

    /// 还没确认过 X-GitHub-Reason 的邮件（升级前同步的旧数据），新的在前。
    func messageIDsMissingReason(limit: Int) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT id FROM message WHERE reason IS NULL ORDER BY internalDate DESC LIMIT ?", arguments: [limit]) }
    }

    func setReasons(_ reasons: [String: String]) throws {
        try db.write { db in
            for (id, reason) in reasons { try db.execute(sql: "UPDATE message SET reason = ? WHERE id = ?", arguments: [reason, id]) }
        }
    }

    func hasMessage(_ id: String) throws -> Bool {
        try db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE id = ?)", arguments: [id]) ?? false }
    }

    func existingIDs() throws -> Set<String> {
        try db.read { Set(try String.fetchAll($0, sql: "SELECT id FROM message")) }
    }

    public var accountEmail: String? { try? state("email") }
    public var historyId: String? { try? state("historyId") }

    // MARK: - Writes

    func replaceLabels(_ labels: [GmailLabel]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM label")
            for label in labels {
                try db.execute(sql: "INSERT INTO label(id, name, type) VALUES (?, ?, ?)", arguments: [label.id, label.name, label.type])
            }
        }
    }

    func upsert(_ messages: [ParsedMessage]) throws {
        try db.write { db in
            for m in messages {
                try db.execute(sql: """
                    INSERT INTO message(id, threadId, historyId, internalDate, subject, fromAddr, toAddr, snippet,
                                        bodyText, bodyHtml, isUnread, hasAttachments, sizeEstimate, reason, prKey, source, kind)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        threadId = excluded.threadId, historyId = excluded.historyId,
                        internalDate = excluded.internalDate, subject = excluded.subject,
                        fromAddr = excluded.fromAddr, toAddr = excluded.toAddr, snippet = excluded.snippet,
                        bodyText = excluded.bodyText, bodyHtml = excluded.bodyHtml,
                        isUnread = excluded.isUnread, hasAttachments = excluded.hasAttachments,
                        sizeEstimate = excluded.sizeEstimate, reason = excluded.reason,
                        prKey = COALESCE(excluded.prKey, message.prKey), source = excluded.source, kind = excluded.kind
                    """,
                    arguments: [m.id, m.threadId, m.historyId, m.internalDate, m.subject, m.from, m.to, m.snippet,
                                m.bodyText, m.bodyHtml, m.isUnread, m.hasAttachments, m.sizeEstimate, m.reason, m.prKey, m.source, m.kind])
                let seq = try Int64.fetchOne(db, sql: "SELECT seq FROM message WHERE id = ?", arguments: [m.id])!
                try db.execute(sql: "INSERT OR REPLACE INTO message_fts(rowid, subject, fromAddr, bodyText) VALUES (?, ?, ?, ?)",
                               arguments: [seq, m.subject, m.from, m.bodyText])
                try Self.writeLabels(db, messageId: m.id, labelIds: m.labelIds)
            }
            try Self.resolveCIKeys(db)
        }
    }

    /// 更新已有邮件的标签；本地没有这封邮件时忽略。
    func setLabels(messageId: String, labelIds: [String]) throws {
        try db.write { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE id = ?)", arguments: [messageId]) ?? false
            guard exists else { return }
            try db.execute(sql: "UPDATE message SET isUnread = ? WHERE id = ?", arguments: [labelIds.contains("UNREAD"), messageId])
            try Self.writeLabels(db, messageId: messageId, labelIds: labelIds)
        }
    }

    func delete(ids: some Collection<String>) throws {
        try db.write { db in
            for id in ids {
                if let seq = try Int64.fetchOne(db, sql: "SELECT seq FROM message WHERE id = ?", arguments: [id]) {
                    try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [seq])
                }
                try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id])
            }
        }
    }

    /// 全量同步结束后清理本地多出来的邮件（已被删除或移出同步范围）。
    func deleteMessages(notIn keep: Set<String>) throws {
        let stale = try db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM message").filter { !keep.contains($0) }
        }
        try delete(ids: stale)
    }

    private static func writeLabels(_ db: Database, messageId: String, labelIds: [String]) throws {
        try db.execute(sql: "DELETE FROM message_label WHERE messageId = ?", arguments: [messageId])
        for label in Set(labelIds) {
            try db.execute(sql: "INSERT INTO message_label(messageId, labelId) VALUES (?, ?)", arguments: [messageId, label])
        }
    }

    /// 按给定的识别配置重新判定所有邮件的类型（用户改了识别规则之后调用）。返回有多少封改变了。
    @discardableResult
    public func reclassifyKinds(config: KindConfig = KindConfigStore.shared.config) throws -> Int {
        try db.write { db in
            var changed = 0
            for row in try Row.fetchAll(db, sql: "SELECT id, subject, fromAddr, kind, substr(bodyText, 1, 6000) AS body FROM message") {
                let kind = MessageClassifier.kind(subject: row["subject"], from: row["fromAddr"], body: row["body"], config: config).rawValue
                if kind != (row["kind"] as String) {
                    try db.execute(sql: "UPDATE message SET kind = ? WHERE id = ?", arguments: [kind, row["id"] as String])
                    changed += 1
                }
            }
            return changed
        }
    }

    // MARK: - Reads

    public func messageCount() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message") ?? 0 }
    }

    func labelIds(of messageId: String) throws -> Set<String> {
        try db.read { Set(try String.fetchAll($0, sql: "SELECT labelId FROM message_label WHERE messageId = ?", arguments: [messageId])) }
    }

    func bodyText(of messageId: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT bodyText FROM message WHERE id = ?", arguments: [messageId]) }
    }

    public func recent(limit: Int) throws -> [MessageSummary] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM message ORDER BY internalDate DESC LIMIT ?", arguments: [limit]).map(Self.summary)
        }
    }

    /// 子串搜索主题/发件人/正文。≥3 个字符走 FTS5 trigram，更短的（如两个汉字）退化为 LIKE。
    public func search(_ text: String, limit: Int) throws -> [MessageSummary] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try db.read { db in
            let rows: [Row]
            if query.count >= 3 {
                let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                rows = try Row.fetchAll(db, sql: """
                    SELECT m.* FROM message_fts JOIN message m ON m.seq = message_fts.rowid
                    WHERE message_fts MATCH ? ORDER BY m.internalDate DESC LIMIT ?
                    """, arguments: [phrase, limit])
            } else {
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM message
                    WHERE subject LIKE ?1 ESCAPE '\\' OR fromAddr LIKE ?1 ESCAPE '\\' OR bodyText LIKE ?1 ESCAPE '\\'
                    ORDER BY internalDate DESC LIMIT ?2
                    """, arguments: [pattern, limit])
            }
            return rows.map(Self.summary)
        }
    }

    static func summary(_ row: Row) -> MessageSummary {
        let millis: Int64 = row["internalDate"]
        return MessageSummary(id: row["id"], threadId: row["threadId"], subject: row["subject"], from: row["fromAddr"],
                              date: Date(timeIntervalSince1970: Double(millis) / 1000),
                              snippet: row["snippet"], isUnread: row["isUnread"])
    }
}
