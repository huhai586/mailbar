import Foundation
import Testing
@testable import MailCore

private func pr(_ id: String, _ title: String, _ number: Int, thread: String, date: Int64, labels: [String] = ["INBOX", "UNREAD"],
                from: String = "dmx <notifications@github.com>", body: String = "body") -> ParsedMessage {
    makeMessage(id, subject: "Re: [acme/web] \(title) (PR #\(number))", from: from, body: body, date: date, labels: labels, thread: thread)
}

private func ci(_ id: String, workflow: String = "Blackbox Tests", title: String, thread: String, date: Int64) -> ParsedMessage {
    makeMessage(id, subject: "[acme/web] PR run failed: \(workflow) - \(title) (2a35293)", from: "GitHub <notifications@github.com>",
                body: "workflow run", date: date, labels: ["INBOX", "UNREAD"], thread: thread)
}

@Suite struct PRKeyTests {
    @Test func keyFromSubjectAndFromBodyLink() {
        #expect(GitHubSubject.prKey(subject: "Re: [a/b] fix thing (PR #7)", body: "") == "a/b#7")
        #expect(GitHubSubject.prKey(subject: "[a/b] crash (Issue #9)", body: "") == "a/b#9")
        // Jira 自动化通知的主题里没有编号，正文里有 PR 链接
        #expect(GitHubSubject.prKey(subject: "[JIRA] (VM-1) title", body: "PR https://github.com/Vungle/Monetize/pull/7132 is merged.") == "Vungle/Monetize#7132")
        #expect(GitHubSubject.prKey(subject: "hello", body: "no links here") == nil)
        #expect(GitHubSubject.splitPRKey("a/b#7")?.number == 7 && GitHubSubject.splitPRKey("a/b#7")?.repo == "a/b")
        #expect(GitHubSubject.splitPRKey("not-a-key") == nil)
    }

    @Test func parseCIRunSubjects() {
        let run = GitHubSubject.parseCIRun("[Vungle/Monetize] PR run failed: Nemo Blackbox Tests - fix(VM-3557): empty the endcard iframe")
        #expect(run == GitHubSubject.CIRun(repo: "Vungle/Monetize", workflow: "Nemo Blackbox Tests", prTitle: "fix(VM-3557): empty the endcard iframe", commit: nil))
        // 真实主题末尾带提交号，不能算进标题
        let withSha = GitHubSubject.parseCIRun("[Vungle/Monetize] PR run failed: Nemo Blackbox Tests - fix(VM-3557): empty the endcard iframe document when its scene exits (2a35293)")
        #expect(withSha?.prTitle == "fix(VM-3557): empty the endcard iframe document when its scene exits" && withSha?.commit == "2a35293")
        #expect(GitHubSubject.parseCIRun("[a/b] PR run failed: W - title (not a sha)")?.prTitle == "title (not a sha)")
        #expect(GitHubSubject.parseCIRun("[a/b] PR run failed: Tests, Attempt #2 - the title")?.workflow == "Tests, Attempt #2")
        #expect(GitHubSubject.parseCIRun("[a/b] Run failed: Review Council - main (737c853)") == nil)    // 分支上的运行，不是 PR
        #expect(GitHubSubject.parseCIRun("Re: [a/b] title (PR #1)") == nil)
    }
}

@Suite struct PRGroupingTests {
    private func store(_ messages: [ParsedMessage]) throws -> MailStore {
        let s = try MailStore(path: nil)
        try s.upsert(messages)
        return s
    }

    @Test func ciFailuresAreLinkedToTheirPRByTitleOnUpsert() throws {
        let s = try store([
            pr("c1", "fix the endcard", 7109, thread: "T-comments", date: 1000),
            ci("r1", title: "fix the endcard", thread: "T-run1", date: 2000),
            ci("r2", workflow: "Previewer", title: "fix the endcard", thread: "T-run2", date: 3000),
            ci("other", title: "some other PR title", thread: "T-run3", date: 4000),     // 对不上任何 PR
        ])
        let rows = try s.threads(in: .allMail, groupByPR: true)
        let group = try #require(rows.first { $0.id == "acme/web#7109" })
        #expect(group.messageCount == 3 && group.threadCount == 3 && group.ciFailures == 2)
        #expect(group.latestMessageId == "r2" && group.latestThreadId == "T-run2" && group.prKey == "acme/web#7109")
        #expect(rows.contains { $0.id == "T-run3" && $0.prKey == nil })               // 没对上的仍按会话
    }

    @Test func ciEmailArrivingBeforeItsPRIsLinkedLater() throws {
        let s = try store([ci("r1", title: "late title", thread: "T-run", date: 1000)])
        #expect(try s.threads(in: .allMail, groupByPR: true).first?.id == "T-run")
        try s.upsert([pr("c1", "late title", 42, thread: "T-c", date: 2000)])
        let rows = try s.threads(in: .allMail, groupByPR: true)
        #expect(rows.count == 1 && rows[0].id == "acme/web#42" && rows[0].messageCount == 2)
    }

    @Test func jiraAutomationMentioningThePRJoinsTheGroup() throws {
        let jira = makeMessage("j1", subject: "[JIRA] (VM-1) title", from: "\"Automation for Jira\" <jira@x.atlassian.net>",
                               body: "PR https://github.com/acme/web/pull/7109 is merged.", date: 3000, labels: ["INBOX"], thread: "T-jira")
        let s = try store([pr("c1", "t", 7109, thread: "T-c", date: 1000), jira])
        let group = try #require(try s.threads(in: .allMail, groupByPR: true).first)
        #expect(group.id == "acme/web#7109" && group.messageCount == 2 && group.threadCount == 2)
    }

    @Test func byThreadModeStillSeparatesThemAndNonPRMailIsUntouched() throws {
        let s = try store([
            pr("c1", "t", 1, thread: "T1", date: 1000), pr("c2", "t", 1, thread: "T2", date: 2000),
            makeMessage("plain", subject: "lunch?", date: 3000, thread: "T3"),
        ])
        #expect(try s.threads(in: .allMail, groupByPR: false).map(\.id) == ["T3", "T2", "T1"])
        let grouped = try s.threads(in: .allMail, groupByPR: true)
        #expect(grouped.map(\.id) == ["T3", "acme/web#1"])
        #expect(grouped.first { $0.id == "T3" }?.threadCount == 1)
    }

    @Test func groupedUnreadAndRuleNamesAggregateAcrossThreads() throws {
        let s = try store([
            pr("c1", "t", 5, thread: "T1", date: 1000, labels: ["INBOX"]),
            pr("c2", "t", 5, thread: "T2", date: 2000, labels: ["INBOX", "UNREAD"]),
        ])
        _ = try s.recordMatch(messageId: "c1", ruleName: "A")
        _ = try s.recordMatch(messageId: "c2", ruleName: "B")
        let group = try #require(try s.threads(in: .allMail, groupByPR: true).first)
        #expect(group.unreadCount == 1 && group.isUnread)
        #expect(group.ruleNames == ["A", "B"])
        #expect(try s.threads(in: .allMail, unreadOnly: true, groupByPR: true).first?.messageCount == 1)
    }

    @Test func messagesInGroupSpanThreadsInTimeOrder() throws {
        let s = try store([
            pr("b", "t", 9, thread: "T2", date: 2000), pr("a", "t", 9, thread: "T1", date: 1000), pr("other", "x", 10, thread: "T9", date: 1500),
        ])
        #expect(try s.messages(inGroup: "acme/web#9").map(\.id) == ["a", "b"])
        #expect(try s.messages(inGroup: "T1").map(\.id) == ["a"])                 // 会话 id 仍然按会话取
        #expect(try s.messages(inGroup: "acme/web#404").isEmpty)
    }

    @Test func searchAndMailboxFiltersApplyBeforeGrouping() throws {
        let s = try store([
            pr("a", "alpha", 1, thread: "T1", date: 1000, labels: ["INBOX"]),
            makeMessage("sent", subject: "Re: [acme/web] alpha (PR #1)", date: 2000, labels: ["SENT"], thread: "T2"),
        ])
        #expect(try s.threads(in: .label("INBOX"), groupByPR: true).first?.messageCount == 1)
        #expect(try s.threads(in: .allMail, search: "alpha", groupByPR: true).first?.messageCount == 2)
    }

    @Test func existingDatabasesGetPRKeysBackfilledByTheMigration() throws {
        // 先建一个 v3 的库（没有 prKey 列），塞几封邮件，再用当前版本打开，看迁移有没有回填
        let path = NSTemporaryDirectory() + "pr-migrate-\(UUID().uuidString)/mail.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        do {
            let s = try MailStore(path: path)
            try s.upsert([pr("c1", "fix the endcard", 7, thread: "T1", date: 1000), ci("r1", title: "fix the endcard", thread: "T2", date: 2000)])
            try s.db.write { db in
                try db.execute(sql: "UPDATE message SET prKey = NULL")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4-pr-key'")
                try db.execute(sql: "DROP INDEX message_prkey")
                try db.execute(sql: "ALTER TABLE message DROP COLUMN prKey")
            }
        }
        let reopened = try MailStore(path: path)
        let group = try #require(try reopened.threads(in: .allMail, groupByPR: true).first)
        #expect(reopened.historyId == nil)
        #expect(group.id == "acme/web#7" && group.messageCount == 2 && group.ciFailures == 1)
    }
}
