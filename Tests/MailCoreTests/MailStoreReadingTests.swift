import Foundation
import Testing
@testable import MailCore

private func store(with messages: [ParsedMessage]) throws -> MailStore {
    let store = try MailStore(path: nil)
    try store.upsert(messages)
    return store
}

@Suite struct ThreadQueryTests {
    @Test func groupsMessagesIntoThreadsShowingTheLatest() throws {
        let s = try store(with: [
            makeMessage("a1", subject: "Topic", from: "alice@x.com", date: 1000, labels: ["INBOX"], thread: "T1"),
            makeMessage("a2", subject: "Re: Topic", from: "bob@x.com", date: 3000, labels: ["INBOX", "UNREAD"], thread: "T1"),
            makeMessage("b1", subject: "Other", date: 2000, labels: ["INBOX"], thread: "T2"),
        ])
        let threads = try s.threads(in: .label("INBOX"))
        #expect(threads.map(\.id) == ["T1", "T2"])                     // 按最新邮件时间倒序
        let t1 = threads[0]
        #expect(t1.latestMessageId == "a2")
        #expect(t1.subject == "Re: Topic" && t1.from == "bob@x.com")
        #expect(t1.messageCount == 2 && t1.unreadCount == 1 && t1.isUnread)
        #expect(!threads[1].isUnread)
    }

    @Test func attachmentFlagComesFromAnyMessageInThread() throws {
        let s = try store(with: [
            makeMessage("a1", date: 1000, thread: "T", attachment: true),
            makeMessage("a2", date: 2000, thread: "T"),
            makeMessage("b", date: 500),
        ])
        let byId = Dictionary(uniqueKeysWithValues: try s.threads(in: .allMail).map { ($0.id, $0) })
        #expect(byId["T"]?.hasAttachments == true)
        #expect(byId["t-b"]?.hasAttachments == false)
    }

    @Test func labelMailboxesFilterAndCountWithinTheFilter() throws {
        let s = try store(with: [
            makeMessage("1", date: 1000, labels: ["INBOX"], thread: "T"),
            makeMessage("2", date: 2000, labels: ["SENT"], thread: "T"),
            makeMessage("3", date: 3000, labels: ["STARRED", "INBOX"]),
        ])
        #expect(try s.threads(in: .label("INBOX")).map(\.id) == ["t-3", "T"])
        #expect(try s.threads(in: .label("INBOX")).last?.messageCount == 1)   // 只数收件箱里的那封
        #expect(try s.threads(in: .label("SENT")).map(\.latestMessageId) == ["2"])
        #expect(try s.threads(in: .label("STARRED")).map(\.latestMessageId) == ["3"])
        #expect(try s.threads(in: .label("NOPE")).isEmpty)
    }

    @Test func unreadMailboxOnlyCountsUnreadInboxMail() throws {
        let s = try store(with: [
            makeMessage("1", date: 1000, labels: ["INBOX", "UNREAD"]),
            makeMessage("2", date: 2000, labels: ["INBOX"]),
            makeMessage("3", date: 3000, labels: ["UNREAD"]),                // 已归档的未读不算
            makeMessage("4", date: 4000, labels: ["SENT", "UNREAD"]),
        ])
        #expect(try s.threads(in: .unread).map(\.latestMessageId) == ["1"])
    }

    @Test func allMailExcludesSpamAndTrash() throws {
        let s = try store(with: [
            makeMessage("1", date: 1000, labels: ["INBOX"]),
            makeMessage("2", date: 2000, labels: ["SPAM"]),
            makeMessage("3", date: 3000, labels: ["TRASH", "INBOX"]),
            makeMessage("4", date: 4000, labels: []),                          // 已归档
        ])
        #expect(try s.threads(in: .allMail).map(\.latestMessageId) == ["4", "1"])
        #expect(try s.threads(in: .label("SPAM")).map(\.latestMessageId) == ["2"])
    }

    @Test func ruleMailbox() throws {
        let s = try store(with: [makeMessage("1", date: 1000), makeMessage("2", date: 2000), makeMessage("3", date: 3000)])
        _ = try s.recordMatch(messageId: "1", ruleName: "告警")
        _ = try s.recordMatch(messageId: "3", ruleName: "告警")
        _ = try s.recordMatch(messageId: "2", ruleName: "老板")
        #expect(try s.threads(in: .rule("告警")).map(\.latestMessageId) == ["3", "1"])
        #expect(try s.threads(in: .rule("老板")).map(\.latestMessageId) == ["2"])
        #expect(try s.threads(in: .rule("无")).isEmpty)
    }

    @Test func searchCombinesWithMailbox() throws {
        let s = try store(with: [
            makeMessage("1", subject: "Quarterly invoice", date: 1000, labels: ["INBOX"]),
            makeMessage("2", subject: "Invoice copy", date: 2000, labels: ["SENT"]),
            makeMessage("3", subject: "服务器告警", body: "磁盘已满", date: 3000, labels: ["INBOX"]),
        ])
        #expect(try s.threads(in: .allMail, search: "invoice").map(\.latestMessageId) == ["2", "1"])
        #expect(try s.threads(in: .label("INBOX"), search: "invoice").map(\.latestMessageId) == ["1"])
        #expect(try s.threads(in: .allMail, search: "告警").map(\.latestMessageId) == ["3"])        // 2 字：LIKE
        #expect(try s.threads(in: .allMail, search: "服务器告警").map(\.latestMessageId) == ["3"])   // ≥3 字：FTS
        #expect(try s.threads(in: .allMail, search: "磁盘已满").map(\.latestMessageId) == ["3"])    // 搜正文
        #expect(try s.threads(in: .allMail, search: "  ").count == 3)                              // 空搜索 = 不过滤
        #expect(try s.threads(in: .label("INBOX"), search: "nomatch").isEmpty)
    }

    @Test func searchWithRuleAndLikeParametersDoNotCollide() throws {
        // LIKE 条件和邮箱条件各带参数，拼在一起不能串号
        let s = try store(with: [makeMessage("1", subject: "告警 A", date: 1000), makeMessage("2", subject: "告警 B", date: 2000)])
        _ = try s.recordMatch(messageId: "1", ruleName: "r")
        #expect(try s.threads(in: .rule("r"), search: "告警").map(\.latestMessageId) == ["1"])
    }

    @Test func paginationWalksThroughAllThreadsWithoutOverlap() throws {
        let s = try store(with: (1...25).map { makeMessage("m\($0)", date: Int64($0) * 1000) })
        let first = try s.threads(in: .allMail, limit: 10, offset: 0)
        let second = try s.threads(in: .allMail, limit: 10, offset: 10)
        let third = try s.threads(in: .allMail, limit: 10, offset: 20)
        #expect(first.count == 10 && second.count == 10 && third.count == 5)
        let ids = (first + second + third).map(\.latestMessageId)
        #expect(Set(ids).count == 25)
        #expect(ids.first == "m25" && ids.last == "m1")
    }
}

@Suite struct ThreadDetailAndLabelTests {
    @Test func threadMessagesAreOldestFirstWithFullContent() throws {
        let s = try store(with: [
            makeMessage("2", subject: "Re: Hi", from: "bob@x.com", body: "second", date: 2000, labels: ["INBOX", "UNREAD"], thread: "T", to: "me@x.com", html: "<p>second</p>"),
            makeMessage("1", subject: "Hi", from: "alice@x.com", body: "first", date: 1000, labels: ["INBOX"], thread: "T"),
            makeMessage("x", date: 5000),
        ])
        let messages = try s.messages(inThread: "T")
        #expect(messages.map(\.id) == ["1", "2"])
        let m = messages[1]
        #expect(m.subject == "Re: Hi" && m.from == "bob@x.com" && m.to == "me@x.com")
        #expect(m.bodyText == "second" && m.bodyHtml == "<p>second</p>")
        #expect(m.isUnread && m.labelIds == ["INBOX", "UNREAD"])
        #expect(messages[0].bodyHtml == nil)
        #expect(try s.messages(inThread: "missing").isEmpty)
    }

    @Test func labelsReportCountsAndUnread() throws {
        let s = try store(with: [
            makeMessage("1", labels: ["INBOX", "UNREAD"]),
            makeMessage("2", labels: ["INBOX"]),
            makeMessage("3", labels: ["Label_1", "UNREAD"]),
        ])
        try s.replaceLabels([
            GmailLabel(id: "INBOX", name: "INBOX", type: "system"),
            GmailLabel(id: "Label_1", name: "项目/A", type: "user"),
            GmailLabel(id: "Label_2", name: "empty", type: "user"),
        ])
        let byId = Dictionary(uniqueKeysWithValues: try s.labels().map { ($0.id, $0) })
        #expect(byId["INBOX"]?.messageCount == 2 && byId["INBOX"]?.unreadCount == 1)
        #expect(byId["Label_1"]?.name == "项目/A" && byId["Label_1"]?.unreadCount == 1)
        #expect(byId["Label_2"]?.messageCount == 0 && byId["Label_2"]?.unreadCount == 0)
        #expect(byId.count == 3)
    }
}
