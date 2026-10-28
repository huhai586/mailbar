import Foundation
import Testing
@testable import MailCore

private let gh = "notifications@github.com"

/// 来自真实邮箱的机器人评论开头。
private enum Sample {
    static let qualityPassed = "sonarqubecloud[bot] left a comment (Vungle/Monetize#7125)\n\n## ![Quality Gate Passed](https://x/qg-passed.png 'Quality Gate Passed') **Quality Gate passed for 'Monetize Nemo'**"
    static let qualityFailed = "sonarqubecloud[bot] left a comment (Vungle/Monetize#7151)\n\n## [![Quality Gate Failed](https://x/qg-failed.png 'Quality Gate Failed')](https://sonarcloud.io) **Quality Gate failed for 'Monetize Nemo'**\nFailed conditions"
    static let bundleOK = "github-actions[bot] left a comment (Vungle/Monetize#7125)\n\n## :briefcase: Nemo Bundle Size Check\n\n### Modern — SDK >= 7.1.0\n| Bundle | Platform | Previous | New | Change |\n| Standard | iOS | 100.39 KB | 100.39 KB | &#128077; -0.00% |"
    static let bundleWarn = "github-actions[bot] left a comment (Vungle/Monetize#7125)\n\n## :briefcase: Nemo Bundle Size Check\n| Standard | iOS | 100 KB | 140 KB | ⚠️ +40% |"
    static let summaryPass = "dmx-monetize left a comment (Vungle/Monetize#7125)\n\n<!-- playwright-report-github-action -- Nemo Previewer Automation Test -->\n\n### 🚀 Nemo Previewer Automation Test Summary for commit c289f5\n\n![passed](https://x)  **1653 passed**\n![flaky](https://x)  **2 flaky**"
    static let summaryFail = "dmx-monetize left a comment (Vungle/Monetize#7125)\n\n### 🚀 Nemo Previewer Automation Test Summary for commit c289f5\n\n**3 failed**   **1653 passed**"
    static let blackboxFailure = "dmx-monetize left a comment (Vungle/Monetize#7110)\n\n<!-- bb-failure-context:ios:sdk=7.7.8:os=27 -->\n## 🔥 iOS Blackbox failure"
    static let councilProgress = "github-actions[bot] left a comment (Vungle/Monetize#7125)\n\n<!-- review-council -->\n## 🏛️ Review Council — _in progress_"
    static let councilVerdict = "github-actions[bot] left a comment (Vungle/Monetize#7125)\n\n<!-- review-council -->\n## 🏛️ Review Council — verdict: approve"
    static let reportPass = "dmx-monetize left a comment (Vungle/Monetize#7110)\n\n<h2>🔬 Nautilus Unit Test Report - Commit 21bb339</h2>\n\n| **Tests 📝** | **Passed ✅** | **Failed ❌** | **Skipped ⏭️** |\n| --- | --- | --- | --- |\n| 7007 | 7005 | 0 | 2 |\n\n### 🎉 **All tests passed!**\n\n<!-- CTRF PR COMMENT TAG: Nautilus -->\n\n-- \nReply to this email directly or view it on GitHub:\nhttps://github.com/Vungle/Monetize/pull/7110#issuecomment-1\nYou are receiving this because your review was requested."
    static let reportFail = "dmx-monetize left a comment (Vungle/Monetize#7110)\n\n<h2>🔬 Nautilus Unit Test Report</h2>\n| **Failed ❌** |\n| 3 |\n### ❌ **3 tests failed**\n<!-- CTRF PR COMMENT TAG: Nautilus -->"
    static let humanWithTemplateComment = "kevin opened a pull request (Vungle/Monetize#9)\n\n<!-- Please describe your change -->\nFixes the crash"
    static let iosSummaryPass = "dmx-monetize left a comment (Vungle/Monetize#7171)\n\n## 🍎 iOS Blackbox Tests Summary [Nemo] (Commit: 76accb9)\n\n| SDK | OS | Device | Pass | Fail | Skip | Timeout | Error | Status | Link |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| 7.1.0 | 16.0 | iPhone 14 Pro Max | 24 | 0 | 24 | 0 | 0 | ✅ Pass | [View](https://x) |"
    static let iosSummaryFail = "dmx-monetize left a comment (Vungle/Monetize#7171)\n\n## 🍎 iOS Blackbox Tests Summary [Nemo] (Commit: 76accb9)\n\n| SDK | Status |\n| --- | --- |\n| 7.1.0 | ❌ Fail |"
    static let human = "kobolsky-vungle left a comment (Vungle/Monetize#7110)\n\n@council can you take another look at the interpreter change?"
}

@Suite struct MessageKindTests {
    private func kind(_ from: String, _ body: String, subject: String = "Re: [Vungle/Monetize] t (PR #1)") -> MessageKind {
        MessageClassifier.kind(subject: subject, from: "\(from) <\(gh)>", body: body)
    }

    @Test func pushNotificationsAreNotHumanDiscussion() {
        #expect(kind("Kevin Obolsky", "@kobolsky-vungle pushed 1 commit.\n\nc289f51  fix(ci): restore id-token") == .push)
        #expect(kind("Kevin Obolsky", "@kobolsky-vungle force-pushed 3 commits.") == .push)
        #expect(kind("Kevin Obolsky", "kobolsky-vungle left a comment\n\nwe pushed 1 commit to fix it") == .human)
    }

    @Test func humanMentioningTemplateWordsIsStillHuman() {
        #expect(kind("Nicholas Byfleet", "nbyfleet left a comment (Vungle/Monetize#7113)\n\nApproved. Would be good to get the blackbox test failures figured out, and conflicts resolved.") == .human)
        #expect(kind("Rock Chan", "rock left a comment (Vungle/Monetize#7077)\n\n@council review code effort=medium\n\nReview HEAD `9eb136c3a3a4`. blackbox quality gate") == .human)
        #expect(kind("dmx-monetize", "dmx-monetize left a comment (Vungle/Monetize#7125)\r\n\r\n## <img src=\"x\" alt=\"Android\"> Android Blackbox Tests Summary [Nemo]\r\n\r\n| SDK |") == .botRoutine)   // CRLF 也认得出标题；没有失败的汇总算例行
        #expect(kind("Liftoff PE team", "pe-liftoff left a comment (Vungle/Monetize#7110)\n\nTest Service: nautilus<br/>Test Result: \u{2705}<br/>Test Report: https://x") == .botRoutine)
        #expect(kind("dmx-monetize", "dmx-monetize left a comment (Vungle/Monetize#7146)\n\n<h2>\u{1F52C} Nautilus Unit Test Report - Commit 06d4e33</h2>\n\nall good") == .botRoutine)
    }

    @Test func routineBotMessages() {
        #expect(kind("\"sonarqubecloud[bot]\"", Sample.qualityPassed) == .botRoutine)
        #expect(kind("\"github-actions[bot]\"", Sample.bundleOK) == .botRoutine)
        #expect(kind("dmx-monetize", Sample.summaryPass) == .botRoutine)          // 不是 [bot] 账号，靠标记 / 模板识别
        #expect(kind("\"github-actions[bot]\"", Sample.councilProgress) == .botRoutine)
        // 报告表头里的 "Failed ❌" 只是列名；隐藏标记在结尾；页脚要先去掉
        #expect(kind("dmx-monetize", Sample.reportPass) == .botRoutine)
        #expect(kind("dmx-monetize", Sample.iosSummaryPass) == .botRoutine)   // "Tests Summary"（复数）全部通过
        #expect(kind("dmx-monetize", Sample.iosSummaryFail) == .botAlert)
    }

    @Test func botMessagesThatSignalAProblem() {
        #expect(kind("\"sonarqubecloud[bot]\"", Sample.qualityFailed) == .botAlert)
        #expect(kind("\"github-actions[bot]\"", Sample.bundleWarn) == .botAlert)
        #expect(kind("dmx-monetize", Sample.summaryFail) == .botAlert)
        #expect(kind("dmx-monetize", Sample.blackboxFailure) == .botAlert)
        #expect(kind("dmx-monetize", Sample.reportFail) == .botAlert)
        // CI 失败通知靠主题识别，发件人是 PR 作者的账号
        #expect(kind("howard-57blocks", "workflow run", subject: "[Vungle/Monetize] PR run failed: Nemo Blackbox Tests - fix (2a35293)") == .botAlert)
    }

    @Test func otherBotsAndHumans() {
        #expect(kind("\"github-actions[bot]\"", Sample.councilVerdict) == .bot)         // 评审结论：要看，但不算例行
        #expect(kind("Kevin Obolsky", Sample.human) == .human)
        #expect(kind("kevin", Sample.humanWithTemplateComment) == .human)       // 真人 PR 描述里的模板注释不算机器人标记
        #expect(kind("Kevin Obolsky", "plain human text without any marker") == .human)
        #expect(MessageClassifier.kind(subject: "Lunch?", from: "Bob <bob@example.com>", body: "<!-- hidden --> Quality Gate passed") == .human)   // 非 GitHub 邮件不按机器人处理
        #expect(MessageClassifier.kind(subject: "[JIRA] (VM-1) t", from: "\"Automation for Jira (JIRA)\" <jira@x.atlassian.net>", body: "PR is merged") == .bot)
    }

    @Test func routineLabels() {
        #expect(MessageClassifier.routineLabel(subject: "", body: Sample.qualityPassed) == "SonarQube 通过")
        #expect(MessageClassifier.routineLabel(subject: "", body: Sample.bundleOK) == "包体积检查")
        #expect(MessageClassifier.routineLabel(subject: "", body: Sample.summaryPass) == "测试汇总")
        #expect(MessageClassifier.routineLabel(subject: "", body: Sample.councilProgress) == "Review Council 进度")
    }
}

@Suite struct TriageQueryTests {
    private func msg(_ id: String, pr: Int, from: String, body: String, date: Int64, unread: Bool = true, thread: String? = nil,
                     reason: String? = nil, subject: String? = nil) -> ParsedMessage {
        makeMessage(id, subject: subject ?? "Re: [acme/web] title \(pr) (PR #\(pr))", from: "\(from) <\(gh)>", body: body, date: date,
                    labels: unread ? ["INBOX", "UNREAD"] : ["INBOX"], thread: thread ?? "T\(pr)", reason: reason)
    }

    private func store(_ messages: [ParsedMessage]) throws -> MailStore {
        let s = try MailStore(path: nil)
        try s.upsert(messages)
        return s
    }

    @Test func messageKindAndSourceAreStoredAndAggregated() throws {
        let s = try store([
            msg("h1", pr: 1, from: "Kevin", body: Sample.human, date: 1000, reason: "review_requested"),
            msg("r1", pr: 1, from: "\"sonarqubecloud[bot]\"", body: Sample.qualityPassed, date: 2000, reason: "review_requested"),
            msg("r2", pr: 1, from: "\"github-actions[bot]\"", body: Sample.bundleOK, date: 3000, reason: "review_requested"),
            msg("a1", pr: 1, from: "dmx-monetize", body: Sample.blackboxFailure, date: 4000, unread: false, reason: "review_requested"),
        ])
        let group = try #require(try s.threads(in: .allMail, groupByPR: true).first)
        #expect(group.messageCount == 4 && group.source == "github")
        #expect(group.humanCount == 1 && group.humanUnread == 1)
        #expect(group.routineCount == 2 && group.routineUnread == 2)
        #expect(group.alertCount == 1 && group.alertUnread == 0)
        #expect(group.reasons == ["review_requested"] && group.hasNotableRelation)
        #expect(group.lastHumanFrom?.contains("Kevin") == true)
        #expect(group.needsAttention && !group.onlyRoutineUnread)
    }

    @Test func routineOnlyUnreadIsNotAttention() throws {
        let s = try store([
            msg("h1", pr: 2, from: "Kevin", body: Sample.human, date: 1000, unread: false, reason: "review_requested"),
            msg("r1", pr: 2, from: "\"sonarqubecloud[bot]\"", body: Sample.qualityPassed, date: 2000, reason: "review_requested"),
        ])
        let group = try #require(try s.threads(in: .allMail, groupByPR: true).first)
        #expect(group.onlyRoutineUnread && !group.needsAttention)
        #expect(try s.threads(in: .attention, groupByPR: true).isEmpty)
        #expect(try s.attentionCount(groupByPR: true) == 0)
    }

    @Test func attentionMailboxCollectsAlertsAndRelatedHumanActivity() throws {
        let s = try store([
            // PR 10：你被请求 Review，真人有新评论 → 待处理
            msg("h10", pr: 10, from: "Kevin", body: Sample.human, date: 5000, reason: "review_requested"),
            // PR 11：只是订阅，真人有新评论 → 不算
            msg("h11", pr: 11, from: "Kevin", body: Sample.human, date: 4000, reason: "subscribed"),
            // PR 12：出问题（质量门失败）→ 待处理，不管关系
            msg("a12", pr: 12, from: "\"sonarqubecloud[bot]\"", body: Sample.qualityFailed, date: 3000, reason: "subscribed"),
            // PR 13：只有例行机器人 → 不算
            msg("r13", pr: 13, from: "\"sonarqubecloud[bot]\"", body: Sample.qualityPassed, date: 2000, reason: "review_requested"),
        ])
        #expect(Set(try s.threads(in: .attention, groupByPR: true).map(\.id)) == ["acme/web#10", "acme/web#12"])
        #expect(try s.attentionCount(groupByPR: true) == 2)
        #expect(try s.sourceCounts(in: .attention, groupByPR: true)["github"]?.groups == 2)
    }

    @Test func sourceFilterAndCounts() throws {
        let jira = makeMessage("j1", subject: "[JIRA] (VM-1) title", from: "\"Automation for Jira\" <jira@x.atlassian.net>", body: "PR is merged", date: 6000, labels: ["INBOX", "UNREAD"], thread: "TJ")
        let plain = makeMessage("p1", subject: "lunch?", date: 7000, labels: ["INBOX"], thread: "TP")
        let s = try store([msg("g1", pr: 20, from: "Kevin", body: Sample.human, date: 5000), jira, plain])
        #expect(try s.threads(in: .label("INBOX"), source: "github", groupByPR: true).map(\.id) == ["acme/web#20"])
        #expect(try s.threads(in: .label("INBOX"), source: "jira", groupByPR: true).map(\.id) == ["TJ"])
        #expect(try s.threads(in: .label("INBOX"), source: "other", groupByPR: true).map(\.id) == ["TP"])
        #expect(try s.threads(in: .label("INBOX"), source: "googleDocs", groupByPR: true).isEmpty)
        let counts = try s.sourceCounts(in: .label("INBOX"), groupByPR: true)
        #expect(counts["github"] == SourceCount(groups: 1, unreadGroups: 1))
        #expect(counts["jira"] == SourceCount(groups: 1, unreadGroups: 1))
        #expect(counts["other"] == SourceCount(groups: 1, unreadGroups: 0))
    }

    @Test func jiraMessageLinkedToAPRBelongsToTheGitHubGroup() throws {
        let jira = makeMessage("j1", subject: "[JIRA] (VM-1) title", from: "\"Automation for Jira\" <jira@x.atlassian.net>",
                               body: "PR https://github.com/acme/web/pull/30 is merged.", date: 6000, labels: ["INBOX", "UNREAD"], thread: "TJ")
        let s = try store([msg("g1", pr: 30, from: "Kevin", body: Sample.human, date: 5000), jira])
        let rows = try s.threads(in: .label("INBOX"), groupByPR: true)
        #expect(rows.count == 1 && rows[0].source == "github" && rows[0].jiraCount == 1 && rows[0].messageCount == 2)
        // 行的标题取 PR 自己的最新一封 GitHub 邮件，而不是最新一封（Jira）
        #expect(rows[0].subject.contains("[JIRA]") && rows[0].prSubject?.contains("[acme/web]") == true)
        #expect(try s.threads(in: .label("INBOX"), source: "jira", groupByPR: true).isEmpty)
    }

    @Test func unreadMessageIDsByKindForOneClickCleanup() throws {
        let s = try store([
            msg("h", pr: 40, from: "Kevin", body: Sample.human, date: 1000),
            msg("r1", pr: 40, from: "\"sonarqubecloud[bot]\"", body: Sample.qualityPassed, date: 2000),
            msg("r2", pr: 40, from: "\"github-actions[bot]\"", body: Sample.bundleOK, date: 3000),
            msg("r3", pr: 40, from: "dmx-monetize", body: Sample.summaryPass, date: 4000, unread: false),
            msg("a", pr: 40, from: "dmx-monetize", body: Sample.blackboxFailure, date: 5000),
        ])
        #expect(Set(try s.unreadMessageIDs(kind: .botRoutine)) == ["r1", "r2"])
        #expect(try s.unreadMessageIDs(kind: .botAlert) == ["a"])
        #expect(try s.unreadMessageIDs(kind: .human) == ["h"])
        #expect(try s.messages(inGroup: "acme/web#40").map(\.messageKind) == [.human, .botRoutine, .botRoutine, .botRoutine, .botAlert])
    }

    @Test func existingDatabasesGetSourceAndKindBackfilled() throws {
        let path = NSTemporaryDirectory() + "triage-migrate-\(UUID().uuidString)/mail.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        do {
            let s = try MailStore(path: path)
            try s.upsert([msg("h", pr: 50, from: "Kevin", body: Sample.human, date: 1000),
                          msg("r", pr: 50, from: "\"sonarqubecloud[bot]\"", body: Sample.qualityPassed, date: 2000)])
            try s.db.write { db in
                try db.execute(sql: "DROP INDEX message_group_key")   // 依赖 kind 列，先删
                try db.execute(sql: "DROP INDEX message_thread_kind_date")
                try db.execute(sql: "DROP INDEX message_pr_source_date")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5-source'")
                try db.execute(sql: "DROP INDEX message_source")
                try db.execute(sql: "DROP INDEX message_kind")
                try db.execute(sql: "ALTER TABLE message DROP COLUMN source")
                try db.execute(sql: "ALTER TABLE message DROP COLUMN kind")
            }
        }
        let reopened = try MailStore(path: path)
        let group = try #require(try reopened.threads(in: .allMail, groupByPR: true).first)
        #expect(group.source == "github" && group.humanCount == 1 && group.routineCount == 1)
    }
}
