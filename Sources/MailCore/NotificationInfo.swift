import Foundation

/// 一封"服务通知邮件"（GitHub / Jira / Google 文档）里提炼出来的信息：干净的标题、所属上下文、编号、事件类型。
/// 列表行、详情页头部、命令面板都从这里取，所以新增一个服务只需要在这里加一种识别。
public struct NotificationInfo: Equatable, Sendable {
    public enum Service: String, Sendable {
        case github, jira, googleDocs

        public var displayName: String {
            switch self {
            case .github: return "GitHub"
            case .jira: return "Jira"
            case .googleDocs: return "Google 文档"
            }
        }
    }

    /// 事件类型标签。color 取值同 Rule.palette；notable 表示"需要你注意"（提及、指派、请求 Review…）
    public struct Event: Equatable, Sendable {
        public let label: String
        public let color: String
        public let notable: Bool
    }

    public let service: Service
    /// 去掉 Re:、[JIRA]、[owner/repo]、(KEY-1) 等前后缀之后的标题
    public let title: String
    /// GitHub：owner/repo；Jira：项目 key；Google 文档：文档类型
    public let context: String?
    /// GitHub：PR #7125；Jira：VM-3565
    public let reference: String?
    public let event: Event?
    /// GitHub 的链接可以直接从主题推出；Jira / Google 文档要看正文（见 NotificationLinks）
    public let githubURL: URL?
    /// 标题里出现的 Jira 编号（GitHub PR 标题常带 `fix(VM-3557): …`），用来在 PR 上显示可跳转的 Jira 标签
    public let jiraKey: String?
    /// CI 失败邮件里的工作流名（如 Nemo Blackbox Tests）
    public let detail: String?
}

public enum GitHubReason {
    /// GitHub 的 X-GitHub-Reason 是"你为什么会收到这个 PR 的通知"，不是"这封邮件本身是什么"：只要你是被请求的 Reviewer，
    /// 这个 PR 之后的每一封（评论、CI、机器人报告）都带 review_requested。给单封邮件打"请求 Review"标签前，
    /// 先确认它真的是那封请求邮件（"@x requested your review on: …"）；这种关系应该标在 PR 上，不是每封邮件上。
    public static func describesThisMessage(reason: String?, body: String, kind: MessageKind = .human, login: String? = nil) -> Bool {
        let head = String(body.prefix(300)).lowercased()
        switch reason {
        case "review_requested": return head.contains("requested your review") || head.contains("requested a review") || head.contains("review requested")
        case "assign": return head.contains("assigned you") || head.contains("assigned to you")
        case "mention", "team_mention":
            // 机器人报告里常带 "@你的用户名"（比如 "Triggered by @you"），GitHub 也因此把整个 PR 之后的邮件都标成 mention：
            // 只有真人写的、并且正文里真的有 @你 的，才算被提及。
            guard kind == .human else { return false }
            guard reason == "mention", let login, !login.isEmpty else { return true }
            return body.range(of: "@" + login, options: .caseInsensitive) != nil
        default: return true
        }
    }

    /// 规则匹配和 PR 关系统计用的 reason：机器人邮件里的"提及"不算（见 describesThisMessage）。
    public static func effective(reason: String, kind: MessageKind) -> String {
        (reason == "mention" || reason == "team_mention") && kind != .human ? "" : reason
    }

    public static func event(for reason: String?) -> NotificationInfo.Event? {
        guard let reason, !reason.isEmpty else { return nil }
        switch reason {
        case "review_requested": return .init(label: "请求 Review", color: "purple", notable: true)
        case "mention": return .init(label: "提及你", color: "orange", notable: true)
        case "team_mention": return .init(label: "团队提及", color: "orange", notable: true)
        case "assign": return .init(label: "指派给你", color: "yellow", notable: true)
        case "ci_activity": return .init(label: "CI", color: "cyan", notable: false)
        case "state_change": return .init(label: "状态变更", color: "gray", notable: false)
        case "security_alert": return .init(label: "安全告警", color: "red", notable: true)
        case "invitation": return .init(label: "邀请", color: "green", notable: true)
        case "author": return .init(label: "你创建的", color: "gray", notable: false)
        case "comment": return .init(label: "评论", color: "gray", notable: false)
        case "subscribed": return .init(label: "订阅", color: "gray", notable: false)
        case "your_activity": return .init(label: "你的操作", color: "gray", notable: false)
        case "manual": return .init(label: "手动订阅", color: "gray", notable: false)
        default: return .init(label: reason, color: "gray", notable: false)
        }
    }
}

public enum NotificationClassifier {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let jiraKeyPattern = try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b"#)

    /// 文本里的 Jira 编号（按出现顺序，去重）。
    public static func jiraKeys(in text: String) -> [String] {
        var seen = Set<String>()
        return jiraKeyPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }.filter { seen.insert($0).inserted }
    }

    /// 判断一封邮件是不是 GitHub / Jira / Google 文档的通知，是的话提炼信息。
    /// - Parameter body: 正文开头（Gmail 的 snippet 就够用），Jira 的事件类型要靠它判断。
    public static func classify(subject: String, from: String, reason: String? = nil, body: String = "") -> NotificationInfo? {
        classifyGitHub(subject: subject, from: from, reason: reason)
            ?? classifyJira(subject: subject, from: from, body: body)
            ?? classifyGoogleDocs(subject: subject, from: from)
    }

    // MARK: GitHub

    private static func classifyGitHub(subject: String, from: String, reason: String?) -> NotificationInfo? {
        let parsed = GitHubSubject.parse(subject)
        guard parsed != nil || (reason?.isEmpty == false) else { return nil }
        // CI 失败邮件：`[repo] PR run failed: <工作流> - <PR 标题>`，标题换成 PR 的标题，工作流名放进 detail
        let ci = GitHubSubject.parseCIRun(subject)
        let title = ci?.prTitle ?? parsed?.title ?? subject
        return NotificationInfo(service: .github, title: title, context: parsed?.repo ?? ci?.repo, reference: parsed?.reference,
                                event: ciEvent(subject) ?? GitHubReason.event(for: reason), githubURL: parsed?.url, jiraKey: jiraKeys(in: title).first,
                                detail: ci.map { run in run.commit.map { "\(run.workflow) · \($0)" } ?? run.workflow })
    }

    private static func ciEvent(_ subject: String) -> NotificationInfo.Event? {
        subject.range(of: #"\brun failed\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            ? .init(label: "CI 失败", color: "red", notable: true) : nil
    }

    // MARK: Jira

    private static let jiraDecorations: [NSRegularExpression] = [
        regex(#"^\s*(?:(?:re|fwd?)\s*:\s*)+"#),
        regex(#"\[\s*jira\s*\]"#),
        regex(#"\(\s*[A-Z][A-Z0-9]{1,9}-\d{1,6}\s*\)"#),
    ]

    private static func classifyJira(subject: String, from: String, body: String) -> NotificationInfo? {
        let sender = from.lowercased()
        guard sender.contains("jira") || sender.contains("atlassian.net") else { return nil }
        guard !sender.contains("confluence"), !sender.contains("@e.atlassian.com") else { return nil }

        let key = jiraKeys(in: subject).first
        var title = subject
        for pattern in jiraDecorations {
            title = pattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        }
        if let key, title.trimmingCharacters(in: .whitespaces).hasPrefix(key) {
            title = String(title.trimmingCharacters(in: .whitespaces).dropFirst(key.count))
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—"))
        if title.isEmpty { title = subject }

        let event = key == nil && isDigest(subject)
            ? NotificationInfo.Event(label: "周报摘要", color: "gray", notable: false)
            : jiraEvent(subject: subject, body: body)
        return NotificationInfo(service: .jira, title: title, context: key.map { String($0.split(separator: "-")[0]) } ?? "Jira",
                                reference: key, event: event, githubURL: nil, jiraKey: key, detail: nil)
    }

    private static func isDigest(_ subject: String) -> Bool {
        subject.range(of: #"weekly update|digest|每周|周报"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 事件类型靠正文开头判断（主题里没有）。需要你注意的（指派、提及）优先。
    private static func jiraEvent(subject: String, body: String) -> NotificationInfo.Event? {
        let text = (subject + "\n" + body.prefix(600)).lowercased()
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if has(#"assigned (?:this issue |the issue |.{0,40})?to you|assigned you|分配给(?:你|您)|指派给(?:你|您)|已分配给"#) {
            return .init(label: "指派给你", color: "yellow", notable: true)
        }
        if has(#"mentioned you|提到了你|提到了您|@你"#) { return .init(label: "提到你", color: "orange", notable: true) }
        if has(#"\bis merged\b|\bwas merged\b|已合并"#) { return .init(label: "PR 已合并", color: "green", notable: false) }
        if has(#"changed the status|transitioned|status changed|状态.{0,6}(?:变更|更改|改为)|from .{0,30} to .{0,30}"#) {
            return .init(label: "状态变更", color: "cyan", notable: false)
        }
        if has(#"commented|added a comment|评论"#) { return .init(label: "评论", color: "gray", notable: false) }
        if has(#"resolved|已解决|\bdone\b"#) { return .init(label: "已解决", color: "green", notable: false) }
        if has(#"created (?:an|the|a) |创建了"#) { return .init(label: "新建", color: "blue", notable: false) }
        return nil
    }

    // MARK: Google 文档

    private static func classifyGoogleDocs(subject: String, from: String) -> NotificationInfo? {
        let sender = from.lowercased()
        guard sender.contains("docs.google.com") || sender.contains("drive-shares") || sender.contains("drive-noreply")
                || sender.contains("comments-noreply") || sender.contains("docs-noreply") else { return nil }
        return NotificationInfo(service: .googleDocs, title: docTitle(from: subject), context: docKind(from: subject), reference: nil,
                                event: docEvent(subject: subject), githubURL: nil, jiraKey: nil, detail: nil)
    }

    private static let quoted = [regex(#"“([^”]+)”"#), regex(#""([^"]+)""#), regex(#"「([^」]+)」"#), regex(#"‘([^’]+)’"#), regex(#"'([^']+)'"#)]

    /// 主题里引号括起来的文档名；没有引号就用整个主题。
    static func docTitle(from subject: String) -> String {
        for pattern in quoted {
            if let match = pattern.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
               let range = Range(match.range(at: 1), in: subject) {
                return String(subject[range])
            }
        }
        return subject
    }

    private static func docKind(from subject: String) -> String {
        let s = subject.lowercased()
        if s.range(of: #"spreadsheet|sheet|表格"#, options: .regularExpression) != nil { return "表格" }
        if s.range(of: #"presentation|slides|幻灯片|演示"#, options: .regularExpression) != nil { return "幻灯片" }
        if s.range(of: #"\bform\b|表单"#, options: .regularExpression) != nil { return "表单" }
        if s.range(of: #"document|\bdoc\b|文档"#, options: .regularExpression) != nil { return "文档" }
        return "Google 文档"
    }

    private static func docEvent(subject: String) -> NotificationInfo.Event? {
        let s = subject.lowercased()
        func has(_ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        if has(#"requested access|requesting access|asking for access|request for access|access request|请求访问|申请访问|请求权限"#) {
            return .init(label: "请求访问", color: "purple", notable: true)
        }
        if has(#"mentioned you|提到了你|提到了您|@你|@您"#) { return .init(label: "提到你", color: "orange", notable: true) }
        if has(#"assigned|action item|分配给|指派|待办"#) { return .init(label: "分配给你", color: "yellow", notable: true) }
        if has(#"shared|invited you|与你共享|与您共享|已与你共享|邀请你|邀请您"#) { return .init(label: "共享给你", color: "green", notable: true) }
        if has(#"suggest|建议"#) { return .init(label: "建议修改", color: "cyan", notable: false) }
        if has(#"comment|replied|评论|回复"#) { return .init(label: "评论", color: "gray", notable: false) }
        return nil
    }
}

/// 从通知邮件找到"在原服务里打开"的链接。
public enum NotificationLinks {
    private static let docURL = try! NSRegularExpression(
        pattern: #"https://(?:docs|drive)\.google\.com/(?:document|spreadsheets|presentation|forms|drawings|file)/d/[A-Za-z0-9_-]+[^\s"'<>)\]]*"#)

    /// - Parameters:
    ///   - jiraHost: 本地邮件里学到的 Jira 站点域名（见 MailStore.jiraHost()），正文里找不到链接时用它拼 /browse/KEY
    ///   - bodies: 要搜索链接的正文（文本和 HTML 都行）
    public static func url(for info: NotificationInfo, jiraHost: String?, bodies: [String]) -> URL? {
        switch info.service {
        case .github:
            return info.githubURL
        case .jira:
            guard let key = info.jiraKey else { return nil }
            let pattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>)\]]+/browse/\#(NSRegularExpression.escapedPattern(for: key))\b"#)
            for body in bodies {
                if let match = pattern?.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let range = Range(match.range, in: body),
                   let url = URL(string: String(body[range])) { return url }
            }
            return jiraHost.flatMap { URL(string: "https://\($0)/browse/\(key)") }
        case .googleDocs:
            for body in bodies {
                if let match = docURL.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let range = Range(match.range, in: body) {
                    let raw = String(body[range]).replacingOccurrences(of: "&amp;", with: "&")
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                    if let url = URL(string: raw) { return url }
                }
            }
            return nil
        }
    }
}
