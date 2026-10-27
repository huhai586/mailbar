import MailCore

/// 侧栏固定的几个邮箱，以及 Gmail 分类标签的中文名。
struct SystemMailbox: Identifiable {
    let mailbox: Mailbox
    let title: String
    let icon: String
    var id: Mailbox { mailbox }
    /// 偏好里用来标识这个邮箱的键
    var key: String {
        switch mailbox {
        case .unread: return "UNREAD"
        case .allMail: return "ALL"
        case .label(let id): return id
        default: return "\(mailbox)"
        }
    }

    static let all: [SystemMailbox] = [
        SystemMailbox(mailbox: .label("INBOX"), title: "收件箱", icon: "tray"),
        SystemMailbox(mailbox: .unread, title: "未读", icon: "envelope.badge"),
        SystemMailbox(mailbox: .label("STARRED"), title: "已加星标", icon: "star"),
        SystemMailbox(mailbox: .label("IMPORTANT"), title: "重要", icon: "flag"),
        SystemMailbox(mailbox: .label("SENT"), title: "已发送", icon: "paperplane"),
        SystemMailbox(mailbox: .label("DRAFT"), title: "草稿", icon: "doc"),
        SystemMailbox(mailbox: .allMail, title: "所有邮件", icon: "tray.full"),
        SystemMailbox(mailbox: .label("SPAM"), title: "垃圾邮件", icon: "xmark.bin"),
        SystemMailbox(mailbox: .label("TRASH"), title: "已删除", icon: "trash"),
    ]

    static let categoryNames: [String: String] = [
        "CATEGORY_PERSONAL": "主要",
        "CATEGORY_SOCIAL": "社交",
        "CATEGORY_PROMOTIONS": "推广",
        "CATEGORY_UPDATES": "更新",
        "CATEGORY_FORUMS": "论坛",
    ]

    /// 列表顶部显示的标题
    static func title(for mailbox: Mailbox, labels: [LabelInfo]) -> String {
        if let system = all.first(where: { $0.mailbox == mailbox }) { return system.title }
        switch mailbox {
        case .label(let id): return categoryNames[id] ?? labels.first { $0.id == id }?.name ?? id
        case .rule(let name): return "规则：\(name)"
        case .anyRule, .important: return "重点"
        case .sourceRest(let source, _):
            let name = ["github": "GitHub", "jira": "Jira", "googleDocs": "Google 文档"][source] ?? source
            return "\(name) · 其他"
        case .attention: return "待处理"
        case .unread: return "未读"
        case .allMail: return "所有邮件"
        }
    }
}

/// 规则在侧栏里属于哪个来源分组。
enum RuleGrouping {
    static func key(_ rule: Rule) -> String {
        // 推荐规则模板里的规则，直接按模板归属
        if RuleTemplates.github.contains(where: { $0.name == rule.name }) { return "github" }
        if RuleTemplates.jira.contains(where: { $0.name == rule.name }) { return "jira" }
        if RuleTemplates.googleDocs.contains(where: { $0.name == rule.name }) { return "googleDocs" }
        let name = rule.name.lowercased()
        if name.hasPrefix("jira") || rule.from.contains(where: { $0.lowercased().contains("atlassian") || $0.lowercased().contains("jira") }) { return "jira" }
        if name.hasPrefix("文档") || rule.from.contains(where: { $0.lowercased().contains("google") }) { return "googleDocs" }
        if !rule.reasons.isEmpty { return "github" }
        return "other"
    }
}
