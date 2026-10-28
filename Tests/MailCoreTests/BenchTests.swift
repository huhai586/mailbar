import Foundation
import Testing
@testable import MailCore

/// 性能基准：只在设置了 MAIL_BENCH_DB（指向邮件库副本）时运行，打印各个查询的耗时。
@Suite struct BenchTests {
    private func ms(_ label: String, repeats: Int = 5, _ body: () throws -> Void) rethrows {
        var best = Double.infinity
        for _ in 0..<repeats {
            let t = Date()
            try body()
            best = min(best, Date().timeIntervalSince(t) * 1000)
        }
        print(String(format: "BENCH %-44@ %8.2f ms", label as NSString, best))
    }

    @Test func queryTimings() throws {
        guard let path = ProcessInfo.processInfo.environment["MAIL_BENCH_DB"] else { return }
        let store = try MailStore(path: path)
        print("BENCH messages:", try store.messageCount())
        try ms("list all (page 100, group PR)") { _ = try store.threads(in: .allMail, groupByPR: true, limit: 101) }
        try ms("list inbox unread") { _ = try store.threads(in: .label("INBOX"), unreadOnly: true, groupByPR: true, limit: 101) }
        try ms("sourceCounts inbox") { _ = try store.sourceCounts(in: .label("INBOX"), groupByPR: true) }
        try ms("labels") { _ = try store.labels() }
        try ms("unreadMatchCounts") { _ = try store.unreadMatchCounts() }
        try ms("unreadThreadCount inbox") { _ = try store.unreadThreadCount(in: .label("INBOX")) }
        try ms("unreadThreadCount important") { _ = try store.unreadThreadCount(in: .important) }
        try ms("attentionCount") { _ = try store.attentionCount(groupByPR: true) }
        try ms("unreadMessageIDs routine") { _ = try store.unreadMessageIDs(kind: .botRoutine) }
        try ms("unreadMessageIDs human") { _ = try store.unreadMessageIDs(kind: .human) }
        try ms("jiraHost") { _ = try store.jiraHost() }
        try ms("detectedGitHubLogin") { _ = try store.detectedGitHubLogin() }
        try ms("threads attention (8)") { _ = try store.threads(in: .attention, groupByPR: true, limit: 8) }
        try ms("list search 'review'") { _ = try store.threads(in: .allMail, search: "review", groupByPR: true, limit: 101) }
        let groups = try store.threads(in: .allMail, groupByPR: true, limit: 400)
        // 消息最多的分组
        var biggest = 0
        var biggestID = ""
        for g in groups.prefix(60) {
            let n = try store.messages(inGroup: g.id).count
            if n > biggest { biggest = n; biggestID = g.id }
        }
        print("BENCH biggest group:", biggestID, biggest, "messages")
        try ms("detail fetch biggest group") { _ = try store.messages(inGroup: biggestID) }
        let loaded = try store.messages(inGroup: biggestID)
        let bytes = loaded.reduce(0) { $0 + ($1.bodyHtml?.utf8.count ?? 0) + $1.bodyText.utf8.count }
        print("BENCH biggest group body bytes:", bytes)
        let copy = try store.messages(inGroup: biggestID)
        try ms("detail Equatable compare (dedupe)") { _ = (loaded == copy) }
    }

    @Test func rowRenderingCosts() throws {
        guard let path = ProcessInfo.processInfo.environment["MAIL_BENCH_DB"] else { return }
        let store = try MailStore(path: path)
        let rows = try store.threads(in: .allMail, groupByPR: true, limit: 100)
        print("BENCH rows:", rows.count)
        // 一次列表重绘里每一行要做的事 × 100 行
        try ms("DateText.dayKey ×100") { for r in rows { _ = DateText.dayKey(r.date) } }
        try ms("DateText.updated ×100") { for r in rows { _ = DateText.updated(r.date) } }
        try ms("DateText.day ×100") { for r in rows { _ = DateText.day(r.date) } }
        try ms("NotificationClassifier.classify ×100") {
            for r in rows { _ = NotificationClassifier.classify(subject: r.prSubject ?? r.subject, from: r.from, reason: r.reason, body: r.snippet) }
        }
        try ms("SnippetText.preview ×100") { for r in rows { _ = SnippetText.preview(r.snippet) } }
        try ms("MailAddress.parse ×100") { for r in rows { _ = MailAddress.parse(r.from) } }
    }
}
