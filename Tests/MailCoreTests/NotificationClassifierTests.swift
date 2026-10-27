import Foundation
import Testing
@testable import MailCore

@Suite struct NotificationClassifierTests {
    // MARK: Jira（样例来自真实邮箱）

    private let jiraFrom = "\"Automation for Jira (JIRA)\" <jira@vungle.atlassian.net>"

    @Test func jiraAutomationMergedNotification() throws {
        let info = try #require(NotificationClassifier.classify(
            subject: "[JIRA] (VM-3552) Nemo Android: playable black screen when backgrounded", from: jiraFrom,
            body: "PR https://github.com/Vungle/Monetize/pull/7132 is merged."))
        #expect(info.service == .jira)
        #expect(info.reference == "VM-3552" && info.context == "VM" && info.jiraKey == "VM-3552")
        #expect(info.title == "Nemo Android: playable black screen when backgrounded")
        #expect(info.event == .init(label: "PR 已合并", color: "green", notable: false))
    }

    @Test func jiraEventsFromBody() {
        func event(_ body: String) -> String? {
            NotificationClassifier.classify(subject: "[JIRA] (AB-1) t", from: jiraFrom, body: body)?.event?.label
        }
        #expect(event("Kevin assigned this issue to you") == "指派给你")
        #expect(event("Kevin 将此问题分配给你") == "指派给你")
        #expect(event("Kevin mentioned you on AB-1") == "提到你")
        #expect(event("Kevin changed the status from To Do to In Progress") == "状态变更")
        #expect(event("Kevin added a comment") == "评论")
        #expect(event("nothing special") == nil)
        // 需要注意的优先于普通事件
        #expect(event("Kevin commented and mentioned you") == "提到你")
    }

    @Test func jiraWeeklyDigestAndNonJiraAtlassianMail() throws {
        let digest = try #require(NotificationClassifier.classify(subject: "Howard Hu, here is your weekly update for 22 Oct",
                                                                  from: "Jira <jira@vungle.atlassian.net>"))
        #expect(digest.service == .jira && digest.event?.label == "周报摘要" && digest.reference == nil)
        #expect(NotificationClassifier.classify(subject: "Make the most of your AI", from: "Atlassian <info@e.atlassian.com>") == nil)
        #expect(NotificationClassifier.classify(subject: "your team is working on these pages", from: "Confluence <confluence@vungle.atlassian.net>") == nil)
    }

    @Test func jiraKeysInTextAndOnGitHubPRTitles() throws {
        #expect(NotificationClassifier.jiraKeys(in: "fix(VM-3557): and VM-12, VM-3557 again, not-a-key-1") == ["VM-3557", "VM-12"])
        let gh = try #require(NotificationClassifier.classify(subject: "Re: [Vungle/Monetize] fix(VM-3557): empty the endcard (PR #7109)",
                                                              from: "dmx <notifications@github.com>", reason: "comment"))
        #expect(gh.service == .github && gh.jiraKey == "VM-3557" && gh.reference == "PR #7109" && gh.context == "Vungle/Monetize")
    }

    // MARK: GitHub

    @Test func githubReasonsAndCIFailure() throws {
        let review = try #require(NotificationClassifier.classify(subject: "[a/b] t (PR #1)", from: "x <notifications@github.com>", reason: "review_requested"))
        #expect(review.event == .init(label: "请求 Review", color: "purple", notable: true))

        let ci = try #require(NotificationClassifier.classify(subject: "[Vungle/Monetize] PR run failed: Nemo Blackbox Tests - fix(VM-3557): empty the endcard",
                                                              from: "GitHub <notifications@github.com>", reason: "ci_activity"))
        #expect(ci.event == .init(label: "CI 失败", color: "red", notable: true))      // CI 失败比 ci_activity 更具体
        #expect(ci.title == "fix(VM-3557): empty the endcard" && ci.detail == "Nemo Blackbox Tests" && ci.reference == nil)
        let withSha = try #require(NotificationClassifier.classify(subject: "[a/b] PR run failed: Tests - the title (e47d049)", from: "GitHub <notifications@github.com>"))
        #expect(withSha.title == "the title" && withSha.detail == "Tests · e47d049")
        #expect(ci.jiraKey == "VM-3557")
    }

    // MARK: Google 文档

    private let docsFrom = "Alice Chen (Google Docs) <comments-noreply@docs.google.com>"

    @Test func googleDocsEvents() throws {
        func info(_ subject: String, from: String? = nil) -> NotificationInfo? {
            NotificationClassifier.classify(subject: subject, from: from ?? docsFrom)
        }
        #expect(info("Alice mentioned you in a comment in “Q4 Roadmap”")?.event?.label == "提到你")
        #expect(info("Alice 在「Q4 路线图」中提到了你")?.event?.label == "提到你")
        #expect(info("Alice assigned you an action item in “Q4 Roadmap”")?.event?.label == "分配给你")
        #expect(info("Alice shared a document with you: “Q4 Roadmap”", from: "Alice (via Google Docs) <drive-shares-dm-noreply@google.com>")?.event?.label == "共享给你")
        #expect(info("Alice 与您共享了「Q4 路线图」", from: "Alice <drive-shares-noreply@google.com>")?.event?.label == "共享给你")
        #expect(info("Bob is requesting access to “Budget”", from: "Bob <drive-shares-dm-noreply@google.com>")?.event?.label == "请求访问")
        #expect(info("Bob requested access to your spreadsheet", from: "Bob <drive-shares-noreply@google.com>")?.event?.label == "请求访问")
        #expect(info("Alice commented on “Q4 Roadmap”")?.event?.label == "评论")
        #expect(info("Alice made suggestions in “Q4 Roadmap”")?.event?.label == "建议修改")
    }

    @Test func googleDocsTitleAndKind() throws {
        let doc = try #require(NotificationClassifier.classify(subject: "Alice commented on “Q4 Roadmap”", from: docsFrom))
        #expect(doc.service == .googleDocs && doc.title == "Q4 Roadmap" && doc.context == "Google 文档")
        #expect(NotificationClassifier.classify(subject: "Bob shared the spreadsheet \"Budget 2027\" with you", from: docsFrom)?.context == "表格")
        #expect(NotificationClassifier.classify(subject: "Alice shared the presentation 'Launch' with you", from: docsFrom)?.context == "幻灯片")
        #expect(NotificationClassifier.classify(subject: "Alice 与您共享了文档「周报」", from: docsFrom)?.title == "周报")
        #expect(NotificationClassifier.classify(subject: "no quotes here", from: docsFrom)?.title == "no quotes here")
    }

    @Test func ordinaryMailIsNotANotification() {
        #expect(NotificationClassifier.classify(subject: "Lunch tomorrow?", from: "Bob <bob@example.com>") == nil)
        #expect(NotificationClassifier.classify(subject: "Your invoice", from: "billing@vendor.com") == nil)
    }
}

@Suite struct NotificationLinksTests {
    private func info(_ subject: String, from: String, reason: String? = nil) -> NotificationInfo {
        NotificationClassifier.classify(subject: subject, from: from, reason: reason)!
    }

    @Test func githubLinkComesFromTheSubject() {
        let i = info("[a/b] t (PR #5)", from: "x <notifications@github.com>")
        #expect(NotificationLinks.url(for: i, jiraHost: nil, bodies: [])?.absoluteString == "https://github.com/a/b/pull/5")
    }

    @Test func jiraLinkPrefersTheBodyThenFallsBackToTheLearnedHost() {
        let i = info("[JIRA] (VM-3566) title", from: "Jira <jira@vungle.atlassian.net>")
        let body = "see https://vungle.atlassian.net/browse/VM-3566?atlOrigin=abc for details"
        #expect(NotificationLinks.url(for: i, jiraHost: nil, bodies: [body])?.absoluteString == "https://vungle.atlassian.net/browse/VM-3566")
        #expect(NotificationLinks.url(for: i, jiraHost: "vungle.atlassian.net", bodies: ["nothing"])?.absoluteString == "https://vungle.atlassian.net/browse/VM-3566")
        #expect(NotificationLinks.url(for: i, jiraHost: nil, bodies: ["nothing"]) == nil)
        // 别的编号的链接不能拿来用
        #expect(NotificationLinks.url(for: i, jiraHost: nil, bodies: ["https://x.atlassian.net/browse/VM-35660"]) == nil)
    }

    @Test func googleDocsLinkFromHtmlOrText() {
        let i = info("Alice commented on “Roadmap”", from: "Alice <comments-noreply@docs.google.com>")
        let html = #"<a href="https://docs.google.com/document/d/1AbC_dEf-9/edit?disco=AAAA&amp;usp=comment_email">Open</a>"#
        #expect(NotificationLinks.url(for: i, jiraHost: nil, bodies: [html])?.absoluteString == "https://docs.google.com/document/d/1AbC_dEf-9/edit?disco=AAAA&usp=comment_email")
        #expect(NotificationLinks.url(for: i, jiraHost: nil, bodies: ["Open: https://docs.google.com/spreadsheets/d/XYZ123/edit."])?.absoluteString
                == "https://docs.google.com/spreadsheets/d/XYZ123/edit")
        #expect(NotificationLinks.url(for: i, jiraHost: nil, bodies: ["no link"]) == nil)
    }

    @Test func jiraHostIsLearnedFromSenders() throws {
        let store = try MailStore(path: nil)
        try store.upsert([
            makeMessage("1", from: "\"Automation for Jira\" <jira@vungle.atlassian.net>"),
            makeMessage("2", from: "Jira <jira@vungle.atlassian.net>"),
            makeMessage("3", from: "Other <jira@other.atlassian.net>"),
            makeMessage("4", from: "x@example.com"),
        ])
        #expect(try store.jiraHost() == "vungle.atlassian.net")
        #expect(try MailStore(path: nil).jiraHost() == nil)
    }
}

@Suite struct JiraAndDocsTemplateTests {
    @Test func templatesAreValidAndMatchRealisticMail() {
        #expect(RuleStore.validate(RuleTemplates.all).isEmpty)
        #expect(Set(RuleTemplates.all.map(\.name)).count == RuleTemplates.all.count)
        func hits(_ rules: [Rule], subject: String, from: String, body: String = "") -> Set<String> {
            Set(RuleSet(rules: rules).matching(Matchable(subject: subject, from: from, body: body)).map(\.name))
        }
        #expect(hits(RuleTemplates.jira, subject: "[JIRA] (VM-1) t", from: "Jira <jira@x.atlassian.net>", body: "Kevin mentioned you").contains("Jira · 被 @ 提及"))
        // Jira 只剩「被 @ 提及」：指派、高优先级、PR 合并都归到侧栏的「其他」
        #expect(hits(RuleTemplates.jira, subject: "[JIRA] (VM-1) t", from: "Jira <jira@x.atlassian.net>", body: "Kevin assigned this issue to you").isEmpty)
        // 不是 Atlassian 发的邮件不会被 Jira 规则命中
        #expect(hits(RuleTemplates.jira, subject: "Blocker issue", from: "Bob <bob@example.com>", body: "mentioned you").isEmpty)

        let docs = "Alice <comments-noreply@docs.google.com>"
        #expect(hits(RuleTemplates.googleDocs, subject: "Alice mentioned you in “Roadmap”", from: docs).contains("文档 · 提到你"))
        #expect(hits(RuleTemplates.googleDocs, subject: "Bob requested access to “Budget”", from: "Bob <drive-shares-dm-noreply@google.com>").contains("文档 · 请求访问"))
        #expect(hits(RuleTemplates.googleDocs, subject: "Alice shared “Roadmap” with you", from: "Alice <drive-shares-noreply@google.com>").contains("文档 · 共享给你"))
        #expect(hits(RuleTemplates.googleDocs, subject: "mentioned you", from: "Bob <bob@example.com>").isEmpty)
    }
}
