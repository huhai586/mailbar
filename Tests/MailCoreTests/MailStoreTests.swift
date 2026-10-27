import Foundation
import Testing
@testable import MailCore

func makeMessage(_ id: String, subject: String = "subject", from: String = "a@b.com", body: String = "body",
                 date: Int64 = 1_700_000_000_000, labels: [String] = ["INBOX"], thread: String? = nil,
                 to: String = "", html: String? = nil, attachment: Bool = false, reason: String? = nil) -> ParsedMessage {
    var parts: [GmailPart] = []
    if let html { parts.append(GmailPart(partId: nil, mimeType: "text/html", filename: nil, headers: nil,
                                         body: GmailBody(attachmentId: nil, size: nil, data: b64url(Data(html.utf8))), parts: nil)) }
    if attachment { parts.append(GmailPart(partId: nil, mimeType: "application/pdf", filename: "a.pdf", headers: nil,
                                           body: GmailBody(attachmentId: "att", size: 1, data: nil), parts: nil)) }
    let plain = GmailPart(partId: nil, mimeType: "text/plain", filename: nil, headers: nil,
                          body: GmailBody(attachmentId: nil, size: nil, data: b64url(Data(body.utf8))), parts: nil)
    return ParsedMessage(GmailMessage(
        id: id, threadId: thread ?? "t-\(id)", labelIds: labels, snippet: "snip", historyId: "1", internalDate: String(date), sizeEstimate: 1,
        payload: GmailPart(partId: nil, mimeType: "multipart/mixed", filename: nil,
                           headers: [GmailHeader(name: "Subject", value: subject), GmailHeader(name: "From", value: from),
                                     GmailHeader(name: "To", value: to)] + (reason.map { [GmailHeader(name: "X-GitHub-Reason", value: $0)] } ?? []),
                           body: nil, parts: [plain] + parts)))
}

@Suite struct MailStoreTests {
    @Test func upsertIsIdempotent() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", subject: "first")])
        try store.upsert([makeMessage("1", subject: "changed")])
        #expect(try store.messageCount() == 1)
        #expect(try store.recent(limit: 10).first?.subject == "changed")
    }

    @Test func recentIsNewestFirst() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("old", date: 1000), makeMessage("new", date: 3000), makeMessage("mid", date: 2000)])
        #expect(try store.recent(limit: 10).map(\.id) == ["new", "mid", "old"])
        #expect(try store.recent(limit: 2).count == 2)
    }

    @Test func englishSearchUsesFTS() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", subject: "Invoice overdue", body: "please pay"),
                          makeMessage("2", subject: "Lunch", body: "see you at noon")])
        #expect(try store.search("voice", limit: 10).map(\.id) == ["1"])
        #expect(try store.search("noon", limit: 10).map(\.id) == ["2"])
        #expect(try store.search("absent", limit: 10).isEmpty)
    }

    @Test func chineseSearchBothShortAndLong() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", subject: "服务器告警通知", body: "磁盘使用率超过 90%"),
                          makeMessage("2", subject: "周报", body: "本周工作总结")])
        #expect(try store.search("告警", limit: 10).map(\.id) == ["1"])        // 2 字：LIKE
        #expect(try store.search("服务器告警", limit: 10).map(\.id) == ["1"])   // ≥3 字：FTS5 trigram
        #expect(try store.search("工作总结", limit: 10).map(\.id) == ["2"])
    }

    @Test func searchEscapesWildcardsAndQuotes() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", subject: "100% done", body: "say \"hi\""), makeMessage("2", subject: "plain")])
        #expect(try store.search("0%", limit: 10).map(\.id) == ["1"])
        #expect(try store.search("\"hi\"", limit: 10).map(\.id) == ["1"])
    }

    @Test func updatedMessageReplacesSearchIndex() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", subject: "alpha topic")])
        try store.upsert([makeMessage("1", subject: "bravo topic")])
        #expect(try store.search("alpha", limit: 10).isEmpty)
        #expect(try store.search("bravo", limit: 10).map(\.id) == ["1"])
    }

    @Test func deleteRemovesMessageLabelsAndIndex() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", subject: "findable subject"), makeMessage("2")])
        try store.delete(ids: ["1"])
        #expect(try store.messageCount() == 1)
        #expect(try store.search("findable", limit: 10).isEmpty)
        #expect(try store.labelIds(of: "1").isEmpty)
    }

    @Test func setLabelsUpdatesUnreadAndIgnoresUnknown() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", labels: ["INBOX", "UNREAD"])])
        #expect(try store.recent(limit: 1).first?.isUnread == true)

        try store.setLabels(messageId: "1", labelIds: ["INBOX", "STARRED"])
        #expect(try store.recent(limit: 1).first?.isUnread == false)
        #expect(try store.labelIds(of: "1") == ["INBOX", "STARRED"])

        try store.setLabels(messageId: "unknown", labelIds: ["INBOX"])
        #expect(try store.messageCount() == 1)
    }

    @Test func deleteMessagesNotInKeepSet() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1"), makeMessage("2"), makeMessage("3")])
        try store.deleteMessages(notIn: ["2"])
        #expect(try store.recent(limit: 10).map(\.id) == ["2"])
    }

    @Test func syncStateRoundTrip() throws {
        let store = try MailStore(path: nil)
        #expect(try store.state("historyId") == nil)
        try store.setState(["historyId": "42", "email": "x@y.com"])
        #expect(store.historyId == "42")
        #expect(store.accountEmail == "x@y.com")
    }

    @Test func fileDatabasePersists() throws {
        let path = NSTemporaryDirectory() + "mailstore-\(UUID().uuidString)/mail.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        do {
            let store = try MailStore(path: path)
            try store.upsert([makeMessage("1", subject: "persisted subject")])
        }
        let reopened = try MailStore(path: path)
        #expect(try reopened.search("persisted", limit: 10).map(\.id) == ["1"])
    }
}
