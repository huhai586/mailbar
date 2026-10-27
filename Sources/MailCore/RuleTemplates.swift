import Foundation

/// 面向程序员的推荐规则。都是"仅筛选"（不弹通知、不响），只在列表里打上彩色标签；
/// 想要提醒的话在规则编辑器里把提醒方式改成「通知」或「强提醒」。
public enum RuleTemplates {
    public static let github: [Rule] = [
        Rule(name: "请求你 Review", keywords: [], reasons: ["review_requested"], notify: false, color: "purple"),
        Rule(name: "被 @ 提及", keywords: [], reasons: ["mention"], notify: false, color: "orange"),
        Rule(name: "指派给你", keywords: [], reasons: ["assign"], notify: false, color: "yellow"),
        Rule(name: "CI 失败", keywords: ["failed", "failing", "失败"], fields: [.subject], notify: false, color: "red"),
        Rule(name: "已合并 / 已关闭", keywords: [], reasons: ["state_change"], notify: false, color: "gray"),
    ]

    /// Jira：通知邮件的事件类型（提到你、指派给你……）只出现在正文里，所以按正文关键词 + 发件人（atlassian）匹配。
    public static let jira: [Rule] = [
        Rule(name: "Jira · 指派给你", keywords: [#"assigned (?:this issue |the issue |.{0,40})?to you|assigned you|分配给(?:你|您)|指派给(?:你|您)"#],
             from: ["atlassian"], regex: true, notify: false, color: "yellow"),
        Rule(name: "Jira · 提到你", keywords: ["mentioned you", "提到了你", "提到了您"], from: ["atlassian"], notify: false, color: "orange"),
        Rule(name: "Jira · 高优先级", keywords: [#"\b(?:blocker|critical|highest|urgent)\b|阻塞|最高优先级|紧急"#], from: ["atlassian"],
             regex: true, notify: false, color: "red"),
        Rule(name: "Jira · PR 已合并", keywords: [" is merged", "已合并"], fields: [.body], from: ["atlassian"], notify: false, color: "green"),
    ]

    /// Google 文档：通知来自 docs.google.com / drive-shares / comments-noreply，事件类型写在主题里（中英文）。
    public static let googleDocs: [Rule] = [
        Rule(name: "文档 · 提到你", keywords: ["mentioned you", "提到了你", "提到了您"], fields: [.subject],
             from: ["docs.google.com", "drive-shares", "comments-noreply"], notify: false, color: "orange"),
        Rule(name: "文档 · 分配给你", keywords: ["assigned", "action item", "分配给", "指派"], fields: [.subject],
             from: ["docs.google.com", "drive-shares", "comments-noreply"], notify: false, color: "yellow"),
        Rule(name: "文档 · 请求访问", keywords: ["requested access", "requesting access", "asking for access", "request for access", "请求访问", "申请访问"], fields: [.subject],
             from: ["docs.google.com", "drive-shares", "drive-noreply"], notify: false, color: "purple"),
        Rule(name: "文档 · 共享给你", keywords: ["shared", "invited you", "共享", "邀请你", "邀请您"], fields: [.subject],
             from: ["docs.google.com", "drive-shares", "drive-noreply"], notify: false, color: "green"),
        Rule(name: "文档 · 评论", keywords: ["commented", "comment", "评论"], fields: [.subject],
             from: ["docs.google.com", "comments-noreply"], notify: false, color: "gray"),
    ]

    /// 按服务分组，设置界面的"模板"菜单用。
    public static let groups: [(name: String, rules: [Rule])] = [("GitHub", github), ("Jira", jira), ("Google 文档", googleDocs)]

    public static var all: [Rule] { groups.flatMap(\.rules) }

    /// 模板里还没有出现在 existing 里的规则（按名字判断）。
    public static func missing(from templates: [Rule], in existing: [Rule]) -> [Rule] {
        let names = Set(existing.map(\.name))
        return templates.filter { !names.contains($0.name) }
    }
}
