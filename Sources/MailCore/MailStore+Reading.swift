import Foundation
import GRDB

/// 阅读界面里可以选中的"邮箱"。
public enum Mailbox: Hashable, Sendable {
    /// Gmail 标签 id：系统标签如 "INBOX"、"STARRED"、"SENT"，或用户标签的 id
    case label(String)
    /// 收件箱里还没读的
    case unread
    /// 除垃圾邮件和已删除之外的全部邮件
    case allMail
    /// 命中某条提醒规则的邮件
    case rule(String)
    /// 命中这些规则里任意一条的邮件
    case anyRule([String])
    /// 某个来源（github / jira / googleDocs）里没命中这些规则的邮件：侧栏每个来源分组底下的「其他」
    case sourceRest(source: String, excluding: [String])
    /// 命中任意已启用规则的邮件（"重点"视图；规则变化时命中记录会被整体重算，所以这里不需要规则名）
    case important
    /// 待处理：收件箱里出问题了（CI 失败等）、或者和你相关的 PR 上有真人的新评论
    case attention
}

/// 邮件列表里的一行：一个会话（Gmail 把同一话题的往来合并显示）。
public struct ThreadSummary: Identifiable, Equatable, Sendable {
    /// 分组的标识：按会话时是 Gmail 的 threadId；按 PR 时，属于某个 PR 的邮件是 prKey（`owner/repo#123`），其余仍是 threadId
    public let id: String
    public let latestMessageId: String
    /// 最新一封邮件所在的 Gmail 会话（用来在 Gmail 里打开）
    public let latestThreadId: String
    /// 这一组里有几个 Gmail 会话（按 PR 聚合时可能是好几个：评论一个、每次 CI 失败各一个……）
    public let threadCount: Int
    /// 这一组里 CI 失败通知的数量
    public let ciFailures: Int
    /// 属于哪个 PR / Issue
    public let prKey: String?
    /// 这一组属于哪个服务："github"（含所有 PR 分组）/ "jira" / "googleDocs" / "other"
    public let source: String
    /// 这一组里 Jira 联动邮件的数量（Jira 自动化通知里提到了这个 PR）
    public let jiraCount: Int
    /// PR 分组里最新一封 GitHub 邮件的主题：行的标题和编号取它，不会被最新一封是 Jira / 别的邮件带偏
    public let prSubject: String?
    public let subject: String
    public let from: String
    public let snippet: String
    public let date: Date
    /// 当前筛选条件下该会话里的邮件数
    public let messageCount: Int
    public private(set) var unreadCount: Int
    public let hasAttachments: Bool
    /// 最新一封邮件的 X-GitHub-Reason（GitHub 通知才有）
    public let reason: String?
    /// 这个会话里的邮件命中过的规则名
    public let ruleNames: [String]
    /// 按邮件类型（见 MessageKind）统计：真人 / 出问题的机器人 / 例行机器人，各自的总数和未读数
    public let humanCount: Int
    public private(set) var humanUnread: Int
    public let alertCount: Int
    public private(set) var alertUnread: Int
    public let routineCount: Int
    public private(set) var routineUnread: Int
    /// 这一组里出现过的 X-GitHub-Reason（你和这个 PR 的关系：请求你 Review、被提及、指派……）
    public let reasons: [String]
    /// 最近一封真人邮件的发件人和时间（最新一封往往是机器人，真人的动静更值得看）
    public let lastHumanFrom: String?
    public let lastHumanDate: Date?

    public var isUnread: Bool { unreadCount > 0 }

    /// 同一行、全部已读后的样子：界面在"已读但先不挪位置"时用它立刻显示已读。
    public func markedRead() -> ThreadSummary {
        var copy = self
        copy.unreadCount = 0
        copy.humanUnread = 0
        copy.alertUnread = 0
        copy.routineUnread = 0
        return copy
    }

    /// 你和这个 PR 有明确关系（被请求 Review、被提及、指派给你、你自己的 PR……）
    public var hasNotableRelation: Bool { !Set(reasons).isDisjoint(with: MailStore.notableReasons) }
    /// 需要处理：出问题了，或者和你相关的 PR 上有真人的新评论
    public var needsAttention: Bool { alertUnread > 0 || (humanUnread > 0 && hasNotableRelation) }
    /// 未读的全是例行机器人消息，可以放心忽略
    public var onlyRoutineUnread: Bool { unreadCount > 0 && humanUnread == 0 && alertUnread == 0 }
}

/// 某个来源下有多少分组、其中几个有未读。
public struct SourceCount: Equatable, Sendable {
    public let groups: Int
    public let unreadGroups: Int
}

public struct MessageDetail: Identifiable, Equatable, Sendable {
    public let id: String
    public let threadId: String
    public let subject: String
    public let from: String
    public let to: String
    public let date: Date
    public let snippet: String
    public let bodyText: String
    public let bodyHtml: String?
    public let isUnread: Bool
    public let hasAttachments: Bool
    public let labelIds: [String]
    /// X-GitHub-Reason（GitHub 通知才有）
    public let reason: String?
    /// MessageKind 的 rawValue：human / bot_routine / bot_alert / bot
    public let kind: String

    public var messageKind: MessageKind { MessageKind(rawValue: kind) ?? .human }

    /// 看起来是 GitHub 通知邮件
    public var isGitHubNotification: Bool { reason != nil || from.localizedCaseInsensitiveContains("@github.com") }
}

public struct LabelInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// "system" 或 "user"
    public let type: String?
    public let messageCount: Int
    public let unreadCount: Int
}

extension MailStore {
    /// 你自己的 GitHub 用户名：从"你触发的工作流"通知（reason 为 ci_activity / your_activity）的发件人里学到。没有就返回 nil。
    public func detectedGitHubLogin() throws -> String? {
        let rows = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT fromAddr, COUNT(*) AS n FROM message WHERE reason IN ('ci_activity', 'your_activity') GROUP BY fromAddr ORDER BY n DESC")
        }
        for row in rows {
            let name = MailAddress.parse(row["fromAddr"] as String).displayName
            if !name.isEmpty, !name.contains(" "), !name.contains("[bot]") { return name }
        }
        return nil
    }

    // MARK: - Threads

    /// 某个邮箱（可再叠加搜索词）里的会话列表，最新的在前。
    /// groupByPR 为 true 时，属于同一个 PR 的邮件（评论、CI 结果、Jira 联动……）合成一行；不属于任何 PR 的仍按会话。
    /// source 不为 nil 时只要这个来源的分组（"github" / "jira" / "googleDocs" / "other"）。
    public func threads(in mailbox: Mailbox, search: String? = nil, unreadOnly: Bool = false, source: String? = nil,
                        groupByPR: Bool = false, limit: Int = 100, offset: Int = 0) throws -> [ThreadSummary] {
        try db.read { db in
            try Self.fetchThreads(db, in: mailbox, search: search, unreadOnly: unreadOnly, source: source,
                                  groupByPR: groupByPR, limit: limit, offset: offset)
        }
    }

    static func fetchThreads(_ db: Database, in mailbox: Mailbox, search: String?, unreadOnly: Bool, source: String?,
                             groupByPR: Bool, limit: Int, offset: Int) throws -> [ThreadSummary] {
        let key = groupByPR ? "COALESCE(prKey, threadId)" : "threadId"
        let mKey = groupByPR ? "COALESCE(m.prKey, m.threadId)" : "m.threadId"
        let mmKey = groupByPR ? "COALESCE(mm.prKey, mm.threadId)" : "mm.threadId"
        let gKey = groupByPR ? "COALESCE(g.prKey, g.threadId)" : "g.threadId"
        var clauses = [Self.mailboxClause(mailbox)]
        if unreadOnly { clauses.append(("isUnread = 1", [])) }
        if let search, let clause = Self.searchClause(search) { clauses.append(clause) }
        let whereSQL = clauses.map { "(\($0.sql))" }.joined(separator: " AND ")
        var arguments = StatementArguments()
        for clause in clauses { arguments += clause.arguments }
        var havings: [String] = []
        if source != nil { havings.append("gsource = ?") }
        if mailbox == .attention { havings.append(Self.attentionHaving) }
        let having = havings.isEmpty ? "" : "HAVING " + havings.joined(separator: " AND ")
        if let source { arguments += [source] }
        arguments += [limit, offset]
        let prGroup = groupByPR ? "MAX(prKey) IS NOT NULL" : "0"

        return try Row.fetchAll(db, sql: """
                SELECT m.*, \(mKey) AS groupKey, t.cnt AS threadCount, t.unread AS unreadCount, t.attach AS attachCount,
                       t.threads AS distinctThreads, t.ci AS ciCount, t.jira AS jiraCount, t.gsource AS groupSource,
                       t.hc AS humanCount, t.hu AS humanUnread, t.ac AS alertCount, t.au AS alertUnread,
                       t.rc AS routineCount, t.ru AS routineUnread, t.reasons AS reasonList,
                       (SELECT g.fromAddr FROM message g WHERE \(gKey) = \(mKey) AND g.kind = 'human'
                        ORDER BY g.internalDate DESC LIMIT 1) AS lastHumanFrom,
                       (SELECT g.internalDate FROM message g WHERE \(gKey) = \(mKey) AND g.kind = 'human'
                        ORDER BY g.internalDate DESC LIMIT 1) AS lastHumanDate,
                       (SELECT g.subject FROM message g WHERE m.prKey IS NOT NULL AND g.prKey = m.prKey AND g.source = 'github'
                        ORDER BY g.internalDate DESC LIMIT 1) AS prSubject,
                       (SELECT group_concat(DISTINCT r.ruleName) FROM rule_match r
                        JOIN message mm ON mm.id = r.messageId WHERE \(mmKey) = \(mKey)) AS ruleList
                FROM message m
                JOIN (
                    SELECT \(key) AS gk, MAX(internalDate) AS maxDate, COUNT(*) AS cnt,
                           SUM(isUnread) AS unread, MAX(hasAttachments) AS attach,
                           COUNT(DISTINCT threadId) AS threads,
                           SUM(CASE WHEN subject LIKE '%run failed%' THEN 1 ELSE 0 END) AS ci,
                           SUM(CASE WHEN source = 'jira' THEN 1 ELSE 0 END) AS jira,
                           \(Self.kindAggregates),
                           CASE WHEN \(prGroup) THEN 'github' ELSE MAX(source) END AS gsource
                    FROM message WHERE \(whereSQL) GROUP BY gk \(having)
                ) t ON \(mKey) = t.gk AND m.internalDate = t.maxDate
                GROUP BY \(mKey)
                ORDER BY m.internalDate DESC
                LIMIT ? OFFSET ?
                """, arguments: arguments).map { row in
                ThreadSummary(id: row["groupKey"], latestMessageId: row["id"], latestThreadId: row["threadId"],
                              threadCount: row["distinctThreads"], ciFailures: row["ciCount"], prKey: row["prKey"],
                              source: row["groupSource"], jiraCount: row["jiraCount"], prSubject: row["prSubject"],
                              subject: row["subject"], from: row["fromAddr"],
                              snippet: row["snippet"], date: Self.date(row["internalDate"]),
                              messageCount: row["threadCount"], unreadCount: row["unreadCount"],
                              hasAttachments: (row["attachCount"] as Int) > 0,
                              reason: (row["reason"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                              ruleNames: ((row["ruleList"] as String?) ?? "").split(separator: ",").map(String.init).sorted(),
                              humanCount: row["humanCount"], humanUnread: row["humanUnread"],
                              alertCount: row["alertCount"], alertUnread: row["alertUnread"],
                              routineCount: row["routineCount"], routineUnread: row["routineUnread"],
                              reasons: ((row["reasonList"] as String?) ?? "").split(separator: ",").map(String.init).sorted(),
                              lastHumanFrom: row["lastHumanFrom"], lastHumanDate: (row["lastHumanDate"] as Int64?).map(Self.date))
            }
    }

    /// 当前邮箱 / 搜索条件下，各来源有多少分组、几个有未读（列表顶部分类标签的数字）。
    public func sourceCounts(in mailbox: Mailbox, search: String? = nil, groupByPR: Bool = false) throws -> [String: SourceCount] {
        try db.read { try Self.fetchSourceCounts($0, in: mailbox, search: search, groupByPR: groupByPR) }
    }

    static func fetchSourceCounts(_ db: Database, in mailbox: Mailbox, search: String?, groupByPR: Bool) throws -> [String: SourceCount] {
        var clauses = [Self.mailboxClause(mailbox)]
        if let search, let clause = Self.searchClause(search) { clauses.append(clause) }
        let whereSQL = clauses.map { "(\($0.sql))" }.joined(separator: " AND ")
        var arguments = StatementArguments()
        for clause in clauses { arguments += clause.arguments }
        let key = groupByPR ? "COALESCE(prKey, threadId)" : "threadId"
        let prGroup = groupByPR ? "MAX(prKey) IS NOT NULL" : "0"
        let having = mailbox == .attention ? "HAVING \(Self.attentionHaving)" : ""
            var result: [String: SourceCount] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT gsource, COUNT(*) AS groups, SUM(CASE WHEN unread > 0 THEN 1 ELSE 0 END) AS unreadGroups FROM (
                    SELECT \(key) AS gk, SUM(isUnread) AS unread,
                           \(Self.kindAggregates),
                           CASE WHEN \(prGroup) THEN 'github' ELSE MAX(source) END AS gsource
                    FROM message WHERE \(whereSQL) GROUP BY gk \(having)
                ) GROUP BY gsource
                """, arguments: arguments) {
                result[row["gsource"]] = SourceCount(groups: row["groups"], unreadGroups: row["unreadGroups"])
            }
            return result
    }

    /// 收件箱里某类邮件的未读邮件 id（"一键清理例行机器人邮件"用）。
    public func unreadMessageIDs(kind: MessageKind) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM message WHERE isUnread = 1 AND kind = ?
                AND id IN (SELECT messageId FROM message_label WHERE labelId = 'INBOX')
                """, arguments: [kind.rawValue])
        }
    }

    /// "待处理"的分组数。
    public func attentionCount(groupByPR: Bool) throws -> Int {
        try sourceCounts(in: .attention, groupByPR: groupByPR).values.reduce(0) { $0 + $1.groups }
    }

    /// 某个邮箱里有未读邮件的会话数（侧栏徽标、菜单栏计数用）。
    public func unreadThreadCount(in mailbox: Mailbox) throws -> Int {
        let clause = Self.mailboxClause(mailbox)
        return try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT threadId) FROM message WHERE isUnread = 1 AND (\(clause.sql))",
                             arguments: clause.arguments) ?? 0
        }
    }

    /// 一个会话里的全部邮件，旧的在前。
    public func messages(inThread threadId: String) throws -> [MessageDetail] {
        try messages(whereSQL: "m.threadId = ?", argument: threadId)
    }

    /// 一个分组（见 ThreadSummary.id）里的全部邮件，旧的在前：prKey 取这个 PR 的所有邮件（跨会话），否则取这个会话。
    public func messages(inGroup id: String) throws -> [MessageDetail] {
        try messages(whereSQL: id.contains("#") ? "m.prKey = ?" : "m.threadId = ?", argument: id)
    }

    private func messages(whereSQL: String, argument: String) throws -> [MessageDetail] {
        try db.read { try Self.fetchMessages($0, whereSQL: whereSQL, argument: argument) }
    }

    static func fetchMessages(_ db: Database, inGroup id: String) throws -> [MessageDetail] {
        try fetchMessages(db, whereSQL: id.contains("#") ? "m.prKey = ?" : "m.threadId = ?", argument: id)
    }

    static func fetchMessages(_ db: Database, whereSQL: String, argument: String) throws -> [MessageDetail] {
        try Row.fetchAll(db, sql: """
                SELECT m.*, (SELECT group_concat(labelId) FROM message_label WHERE messageId = m.id) AS labels
                FROM message m WHERE \(whereSQL) ORDER BY m.internalDate ASC, m.seq ASC
                """, arguments: [argument]).map { row in
                let labels: String? = row["labels"]
                return MessageDetail(id: row["id"], threadId: row["threadId"], subject: row["subject"], from: row["fromAddr"],
                                     to: row["toAddr"], date: Self.date(row["internalDate"]), snippet: row["snippet"],
                                     bodyText: row["bodyText"], bodyHtml: row["bodyHtml"], isUnread: row["isUnread"],
                                     hasAttachments: row["hasAttachments"],
                                     labelIds: labels.map { $0.split(separator: ",").map(String.init).sorted() } ?? [],
                                     reason: (row["reason"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                                     kind: row["kind"])
            }
    }

    /// 某个 Gmail 会话所属的 PR（会话里任意一封邮件有 prKey 即可）。
    public func prKey(forThread threadId: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT prKey FROM message WHERE threadId = ? AND prKey IS NOT NULL LIMIT 1", arguments: [threadId]) }
    }

    /// 本地邮件里学到的 Jira 站点域名（取发件人里最常见的 xxx.atlassian.net）。
    public func jiraHost() throws -> String? {
        let senders = try db.read { db in
            try String.fetchAll(db, sql: "SELECT fromAddr FROM message WHERE fromAddr LIKE '%.atlassian.net%' ORDER BY internalDate DESC LIMIT 200")
        }
        let pattern = try NSRegularExpression(pattern: #"@([a-z0-9-]+\.atlassian\.net)"#, options: [.caseInsensitive])
        var counts: [String: Int] = [:]
        for sender in senders {
            guard let match = pattern.firstMatch(in: sender, range: NSRange(sender.startIndex..., in: sender)),
                  let range = Range(match.range(at: 1), in: sender) else { continue }
            counts[String(sender[range]).lowercased(), default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: - Labels

    /// 所有 Gmail 标签及其本地邮件数 / 未读数。
    public func labels() throws -> [LabelInfo] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.id, l.name, l.type, COUNT(m.id) AS total, COALESCE(SUM(m.isUnread), 0) AS unread
                FROM label l
                LEFT JOIN message_label ml ON ml.labelId = l.id
                LEFT JOIN message m ON m.id = ml.messageId
                GROUP BY l.id ORDER BY l.name COLLATE NOCASE
                """).map { row in
                LabelInfo(id: row["id"], name: row["name"], type: row["type"], messageCount: row["total"], unreadCount: row["unread"])
            }
        }
    }

    // MARK: - Query building

    typealias Clause = (sql: String, arguments: StatementArguments)

    /// 你和一个 PR 有明确关系的 X-GitHub-Reason。
    static let notableReasons: Set<String> = ["review_requested", "mention", "team_mention", "assign", "author", "ci_activity", "security_alert", "invitation"]

    /// 分组里按邮件类型的聚合（hc/hu：真人总数/未读，ac/au：出问题的机器人，rc/ru：例行机器人，rel：和你有明确关系的邮件数）。
    static let kindAggregates = """
        SUM(CASE WHEN kind = 'human' THEN 1 ELSE 0 END) AS hc,
        SUM(CASE WHEN kind = 'human' AND isUnread = 1 THEN 1 ELSE 0 END) AS hu,
        SUM(CASE WHEN kind = 'bot_alert' THEN 1 ELSE 0 END) AS ac,
        SUM(CASE WHEN kind = 'bot_alert' AND isUnread = 1 THEN 1 ELSE 0 END) AS au,
        SUM(CASE WHEN kind = 'bot_routine' THEN 1 ELSE 0 END) AS rc,
        SUM(CASE WHEN kind = 'bot_routine' AND isUnread = 1 THEN 1 ELSE 0 END) AS ru,
        SUM(CASE WHEN reason IN ('review_requested','mention','team_mention','assign','author','ci_activity','security_alert','invitation') THEN 1 ELSE 0 END) AS rel,
        group_concat(DISTINCT CASE WHEN reason IS NOT NULL AND reason != '' AND NOT (reason IN ('mention', 'team_mention') AND kind != 'human') THEN reason END) AS reasons
        """

    /// "待处理"：有出问题的未读，或者（和你有明确关系 且 有真人的未读）。
    static let attentionHaving = "(au > 0 OR (hu > 0 AND rel > 0))"

    private static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    static func mailboxClause(_ mailbox: Mailbox) -> Clause {
        switch mailbox {
        case .label(let id):
            return ("id IN (SELECT messageId FROM message_label WHERE labelId = ?)", [id])
        case .unread:
            return ("isUnread = 1 AND id IN (SELECT messageId FROM message_label WHERE labelId = 'INBOX')", [])
        case .allMail:
            return ("id NOT IN (SELECT messageId FROM message_label WHERE labelId IN ('SPAM', 'TRASH'))", [])
        case .rule(let name):
            return ("id IN (SELECT messageId FROM rule_match WHERE ruleName = ?)", [name])
        case .important:
            return ("id IN (SELECT messageId FROM rule_match)", [])
        case .attention:
            return ("id IN (SELECT messageId FROM message_label WHERE labelId = 'INBOX')", [])
        case .sourceRest(let source, let names):
            guard !names.isEmpty else { return ("source = ?", [source]) }
            let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
            return ("source = ? AND id NOT IN (SELECT messageId FROM rule_match WHERE ruleName IN (\(marks)))",
                    StatementArguments([source] + names))
        case .anyRule(let names):
            guard !names.isEmpty else { return ("0", []) }
            let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
            return ("id IN (SELECT messageId FROM rule_match WHERE ruleName IN (\(marks)))", StatementArguments(names))
        }
    }

    /// ≥3 个字符走 FTS5 trigram；更短的（如两个汉字）退化为 LIKE。空查询返回 nil。
    static func searchClause(_ text: String) -> Clause? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if query.count >= 3 {
            let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return ("seq IN (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)", [phrase])
        }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        // 不用 ?1 这类编号参数：它会和拼进同一条语句的其他 ? 参数串号
        return ("subject LIKE ? ESCAPE '\\' OR fromAddr LIKE ? ESCAPE '\\' OR bodyText LIKE ? ESCAPE '\\'", [pattern, pattern, pattern])
    }
}
