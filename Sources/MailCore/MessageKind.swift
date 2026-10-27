import Foundation

/// 一封邮件对"我要不要管"的意义。列表按它分层：真人 > 出问题的机器人 > 其他机器人 > 例行机器人。
public enum MessageKind: String, Sendable {
    /// 真人写的
    case human
    /// 机器人说"一切正常"：质量门通过、包体积没变、测试全过、评审进行中……基本不用看
    case botRoutine = "bot_routine"
    /// 机器人说"出问题了"：CI 失败、质量门失败、测试有失败……
    case botAlert = "bot_alert"
    /// 其他机器人（评审结论、Jira 自动化……）
    case bot
    /// 有人推送了提交（"@x pushed 1 commit."）：是动态，不是讨论
    case push
}

public enum MessageClassifier {
    private static let cache = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let hit = cache.object(forKey: pattern as NSString) { return hit }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache.setObject(regex, forKey: pattern as NSString)
        return regex
    }

    /// 不用 String.range(of:)：它要求匹配落在字符边界上，"⚠️" 这样的组合 emoji 只匹配前半个会被当成没匹配上。
    private static func has(_ text: String, _ pattern: String) -> Bool {
        guard !pattern.isEmpty, let regex = regex(pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func matches(_ item: KindConfig.Override, subject: String, from: String, body: String) -> Bool {
        guard item.enabled, !item.pattern.isEmpty else { return false }
        let text: String
        switch item.field {
        case .sender: text = from
        case .subject: text = subject
        case .body: text = String(body.prefix(6000))
        }
        return item.regex ? has(text, item.pattern) : text.localizedCaseInsensitiveContains(item.pattern)
    }

    public static func kind(subject: String, from: String, body: String) -> MessageKind {
        kind(subject: subject, from: from, body: body, config: KindConfigStore.shared.config)
    }

    /// 判断邮件类型。先看用户的覆盖规则；再按内置思路：GitHub 机器人评论有稳定的指纹——开头藏着 `<!-- 标记 -->`
    /// （它们靠标记更新自己的评论），或者是机器人账号，或者评论的标题是 "Test Summary / Bundle Size Check / Quality Gate" 这类固定模板。
    public static func kind(subject: String, from: String, body: String, config: KindConfig) -> MessageKind {
        if let hit = config.overrides.first(where: { matches($0, subject: subject, from: from, body: body) }) { return hit.messageKind }

        let sender = from.lowercased()
        let isBotAccount = config.botSenders.contains { !$0.isEmpty && sender.contains($0.lowercased()) }
        // GitHub Actions 的 CI 失败通知
        if has(subject, config.subjectAlertPattern) { return .botAlert }
        guard sender.contains("notifications@github.com") || isBotAccount else { return .human }

        if has(String(body.prefix(200)), config.pushPattern) { return .push }

        // 去掉页脚（"-- / Reply to this email directly …"）；表格表头里的 "Failed ❌" 只是列名，不是失败
        var content = String(body.prefix(6000))
        if let footer = content.range(of: #"\n--\s*\n(?:Reply to this email|View it on GitHub)"#, options: .regularExpression) {
            content = String(content[..<footer.lowerBound])
        }
        let cleaned = content.replacingOccurrences(of: "Failed ❌", with: "")

        // 机器人评论会藏一个 <!-- 标记 -->（开头或结尾都有），靠它更新自己的评论；只在"评论"类邮件里认，免得把真人 PR 描述模板里的注释当成机器人
        let isComment = has(String(content.prefix(200)), #"left a comment"#)
        let marker = isComment && has(content, #"<!--[^>]*-->"#)
        // 固定模板的报告，标题（评论的第一行正文）就是报告名，如 "<h2>🔬 Nautilus Unit Test Report</h2>"。
        // 只看标题：真人评论里顺口提到 "blackbox"、"quality gate"（比如 "Approved，blackbox 测试还要看看"）不能算机器人。
        let template = has(firstBodyLine(of: content), config.templatePattern)
        guard isBotAccount || marker || template else { return .human }

        if has(cleaned, config.alertPattern) { return .botAlert }
        if has(content, config.routinePattern) { return .botRoutine }
        return .bot
    }

    /// 评论的第一行正文（跳过 "x left a comment (repo#n)" 那行）；不像标题（# / <h2> / ** / 开头是 emoji）的话返回空。
    static func firstBodyLine(of content: String) -> String {
        let lines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 1 else { return "" }
        let line = lines[1]
        // 另一种固定格式：QA 平台的 "Test Service: … / Test Result: ✅" 报告
        return has(line, #"^(?:#{1,6}\s|<h[1-6]\b|\*\*|[\p{So}\p{Sk}]|test service:)"#) ? line : ""
    }

    /// 例行机器人消息的一句话说明（折叠行里用）。
    public static func routineLabel(subject: String, body: String) -> String {
        let head = String(body.prefix(2500))
        if has(head, #"quality gate passed"#) { return "SonarQube 通过" }
        if has(head, #"bundle size check"#) { return "包体积检查" }
        if has(head, #"test summary|test report"#) { return "测试汇总" }
        if has(head, #"review council"#) { return "Review Council 进度" }
        return "机器人消息"
    }
}
