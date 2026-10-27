import Foundation

/// 解析完成、可以直接入库和做关键词匹配的邮件。
struct ParsedMessage: Equatable {
    var id: String
    var threadId: String
    var historyId: String?
    var internalDate: Int64
    var subject: String
    var from: String
    var to: String
    var snippet: String
    var bodyText: String
    var bodyHtml: String?
    var labelIds: [String]
    var hasAttachments: Bool
    var sizeEstimate: Int?
    /// GitHub 通知邮件的 X-GitHub-Reason（小写）；"" 表示这封邮件没有；nil 表示还没确认（旧数据，待回填）
    var reason: String?
    /// 这封邮件属于哪个 PR / Issue（`owner/repo#123`）；CI 失败邮件这种没有编号的由 MailStore 事后按标题补上
    var prKey: String?
    /// 来自哪个服务："github" / "jira" / "googleDocs"，都不是则 "other"
    var source: String
    /// MessageKind 的 rawValue：human / bot_routine / bot_alert / bot
    var kind: String

    var isUnread: Bool { labelIds.contains("UNREAD") }

    init(_ message: GmailMessage) {
        let body = MimeParser.parse(message.payload)
        id = message.id
        threadId = message.threadId
        historyId = message.historyId
        internalDate = message.internalDate.flatMap(Int64.init) ?? 0
        subject = HeaderDecoder.decode(message.payload?.header("Subject"))
        from = HeaderDecoder.decode(message.payload?.header("From"))
        to = HeaderDecoder.decode(message.payload?.header("To"))
        snippet = message.snippet ?? ""
        bodyText = body.text
        bodyHtml = body.html
        labelIds = message.labelIds ?? []
        hasAttachments = body.hasAttachments
        sizeEstimate = message.sizeEstimate
        reason = (message.payload?.header("X-GitHub-Reason") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        prKey = GitHubSubject.prKey(subject: subject, body: body.text)
        kind = MessageClassifier.kind(subject: subject, from: from, body: body.text).rawValue
        source = NotificationClassifier.classify(subject: subject, from: from, reason: reason, body: snippet)?.service.rawValue ?? "other"
    }
}
