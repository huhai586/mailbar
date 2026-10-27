import Foundation
import GRDB

/// 规则编辑时的"试匹配"结果：这条规则会命中多少封本地邮件，以及最新的几封。
public struct RulePreview: Equatable, Sendable {
    public let matchCount: Int
    public let samples: [MessageSummary]
}

extension MailStore {
    /// 用规则（不管是否启用）试匹配本地全部邮件，不产生任何提醒或记录。
    public func preview(rule: Rule, sampleLimit: Int = 5) throws -> RulePreview {
        var candidate = rule
        candidate.enabled = true
        let set = RuleSet(rules: [candidate])

        var ids: [String] = []
        var after: Int64 = 0
        while true {
            let page = try matchables(afterSeq: after, limit: 200)
            guard let last = page.last else { break }
            for item in page where !set.matching(item.matchable).isEmpty { ids.append(item.id) }
            after = last.seq
        }
        return RulePreview(matchCount: ids.count, samples: try newestSummaries(of: ids, limit: sampleLimit))
    }

    private func newestSummaries(of ids: [String], limit: Int) throws -> [MessageSummary] {
        guard !ids.isEmpty, limit > 0 else { return [] }
        var result: [MessageSummary] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM message WHERE id IN (\(marks)) ORDER BY internalDate DESC LIMIT ?",
                                 arguments: StatementArguments(chunk) + [limit])
            }
            result += rows.map(Self.summary)
        }
        return Array(result.sorted { $0.date > $1.date }.prefix(limit))
    }
}
