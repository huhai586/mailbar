import Foundation
import Testing
@testable import MailCore

/// 内存里的假 Gmail：可以增删邮件、改标签，并按 historyId 生成 history。
final class FakeGmail: GmailAPI, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String: GmailMessage] = [:]
    private var order: [String] = []                       // 新 -> 旧
    private var records: [(id: Int, record: HistoryRecord)] = []
    private var currentHistory = 100
    var oldestValidHistory = 0
    private(set) var historyCalls = 0
    private(set) var listCalls = 0

    var historyId: String { lock.withLock { String(currentHistory) } }

    private func bump() -> Int { currentHistory += 1; return currentHistory }

    private static func change(_ m: GmailMessage, labels: [String]? = nil) -> HistoryRecord.Change {
        HistoryRecord.Change(message: GmailMessageRef(id: m.id, threadId: m.threadId, labelIds: m.labelIds), labelIds: labels)
    }

    private static func gmailMessage(_ id: String, subject: String, labels: [String], body: String, from: String, date: Int64) -> GmailMessage {
        GmailMessage(id: id, threadId: "t-\(id)", labelIds: labels, snippet: "snip", historyId: nil,
                     internalDate: String(date), sizeEstimate: 1,
                     payload: GmailPart(partId: nil, mimeType: "text/plain", filename: nil,
                                        headers: [GmailHeader(name: "Subject", value: subject), GmailHeader(name: "From", value: from)],
                                        body: GmailBody(attachmentId: nil, size: nil, data: b64url(Data(body.utf8))), parts: nil))
    }

    func add(_ id: String, subject: String = "s", labels: [String] = ["INBOX", "UNREAD"],
             body: String? = nil, from: String = "sender@example.com", date: Int64 = 1_700_000_000_000) {
        lock.withLock {
            let m = Self.gmailMessage(id, subject: subject, labels: labels, body: body ?? "body of \(id)", from: from, date: date)
            messages[id] = m
            order.insert(id, at: 0)
            let h = bump()
            records.append((h, HistoryRecord(id: String(h), messagesAdded: [Self.change(m)], messagesDeleted: nil, labelsAdded: nil, labelsRemoved: nil)))
        }
    }

    func remove(_ id: String) {
        lock.withLock {
            guard let m = messages.removeValue(forKey: id) else { return }
            order.removeAll { $0 == id }
            let h = bump()
            records.append((h, HistoryRecord(id: String(h), messagesAdded: nil, messagesDeleted: [Self.change(m)], labelsAdded: nil, labelsRemoved: nil)))
        }
    }

    func removeLabel(_ label: String, from id: String) {
        lock.withLock {
            guard let m = messages[id] else { return }
            let labels = (m.labelIds ?? []).filter { $0 != label }
            let updated = GmailMessage(id: m.id, threadId: m.threadId, labelIds: labels, snippet: m.snippet, historyId: m.historyId,
                                       internalDate: m.internalDate, sizeEstimate: m.sizeEstimate, payload: m.payload)
            messages[id] = updated
            let h = bump()
            records.append((h, HistoryRecord(id: String(h), messagesAdded: nil, messagesDeleted: nil, labelsAdded: nil,
                                             labelsRemoved: [Self.change(updated, labels: [label])])))
        }
    }

    // GmailAPI

    /// message id -> X-GitHub-Reason（没设置的返回 ""）
    var reasonHeaders: [String: String] = [:]
    private(set) var reasonCalls = 0

    func reasonHeader(id: String) async throws -> String? {
        lock.withLock {
            reasonCalls += 1
            guard messages[id] != nil else { return nil }
            return reasonHeaders[id] ?? ""
        }
    }

    private(set) var batchCalls: [(ids: [String], add: [String], remove: [String])] = []
    var batchModifyError: Error?

    func batchModify(ids: [String], addLabelIds: [String], removeLabelIds: [String]) async throws {
        try lock.withLock {
            if let batchModifyError { throw batchModifyError }
            batchCalls.append((ids, addLabelIds, removeLabelIds))
            for id in ids {
                guard let m = messages[id] else { continue }
                var labels = (m.labelIds ?? []).filter { !removeLabelIds.contains($0) }
                labels += addLabelIds.filter { !labels.contains($0) }
                let updated = GmailMessage(id: m.id, threadId: m.threadId, labelIds: labels, snippet: m.snippet, historyId: m.historyId,
                                           internalDate: m.internalDate, sizeEstimate: m.sizeEstimate, payload: m.payload)
                messages[id] = updated
                let h = bump()
                records.append((h, HistoryRecord(id: String(h), messagesAdded: nil, messagesDeleted: nil,
                                                 labelsAdded: addLabelIds.isEmpty ? nil : [Self.change(updated, labels: addLabelIds)],
                                                 labelsRemoved: removeLabelIds.isEmpty ? nil : [Self.change(updated, labels: removeLabelIds)])))
            }
        }
    }

    func profile() async throws -> GmailProfile {
        lock.withLock { GmailProfile(emailAddress: "me@example.com", historyId: String(currentHistory)) }
    }

    func labels() async throws -> [GmailLabel] { [GmailLabel(id: "INBOX", name: "INBOX", type: "system")] }

    func listMessageIDs(limit: Int) async throws -> [String] {
        lock.withLock { listCalls += 1; return Array(order.prefix(limit)) }
    }

    /// 设置后，第 n 次之后的 message() 调用都会抛限流错误
    var failMessageCallsAfter: Int?
    private(set) var messageCalls = 0

    func message(id: String) async throws -> GmailMessage? {
        try lock.withLock {
            messageCalls += 1
            if let limit = failMessageCallsAfter, messageCalls > limit {
                throw MailError.http(status: 403, body: "rateLimitExceeded")
            }
            return messages[id]
        }
    }

    func stopFailing() { lock.withLock { failMessageCallsAfter = nil } }
    var calls: Int { lock.withLock { messageCalls } }

    func history(since startHistoryId: String) async throws -> (records: [HistoryRecord], historyId: String?) {
        try lock.withLock {
            historyCalls += 1
            guard let start = Int(startHistoryId), start >= oldestValidHistory else { throw MailError.historyExpired }
            return (records.filter { $0.id > start }.map(\.record), String(currentHistory))
        }
    }
}

@Suite struct SyncEngineTests {
    private func makeEngine(_ api: FakeGmail, limit: Int = 500) throws -> (SyncEngine, MailStore) {
        let store = try MailStore(path: nil)
        return (SyncEngine(api: api, store: store, initialLimit: limit, concurrency: 3, log: { _ in }), store)
    }

    @Test func firstSyncIsFullAndRecordsHistoryId() async throws {
        let api = FakeGmail()
        for i in 1...120 { api.add("m\(i)") }
        let (engine, store) = try makeEngine(api)

        let summary = try await engine.sync()
        #expect(summary.mode == .full)
        #expect(summary.fetched == 120)
        #expect(try store.messageCount() == 120)
        #expect(store.historyId == api.historyId)
        #expect(store.accountEmail == "me@example.com")
    }

    @Test func fullSyncRespectsLimit() async throws {
        let api = FakeGmail()
        for i in 1...10 { api.add("m\(i)") }
        let (engine, store) = try makeEngine(api, limit: 4)
        _ = try await engine.sync()
        #expect(try store.messageCount() == 4)
        #expect(try store.recent(limit: 10).count == 4)
    }

    @Test func secondSyncIsIncrementalAndAppliesAllChangeKinds() async throws {
        let api = FakeGmail()
        api.add("a"); api.add("b"); api.add("c")
        let (engine, store) = try makeEngine(api)
        _ = try await engine.sync()

        api.add("d", subject: "brand new")
        api.remove("a")
        api.removeLabel("UNREAD", from: "b")

        let summary = try await engine.sync()
        #expect(summary == SyncSummary(mode: .incremental, fetched: 1, deleted: 1, relabeled: 1))
        #expect(try store.recent(limit: 10).map(\.id).sorted() == ["b", "c", "d"])
        #expect(try store.labelIds(of: "b") == ["INBOX"])
        #expect(try store.search("brand", limit: 5).map(\.id) == ["d"])
        #expect(store.historyId == api.historyId)
        #expect(api.listCalls == 1)   // 增量同步没有重新列邮件
    }

    @Test func noChangesIsANoOp() async throws {
        let api = FakeGmail()
        api.add("a")
        let (engine, store) = try makeEngine(api)
        _ = try await engine.sync()
        let summary = try await engine.sync()
        #expect(summary == SyncSummary(mode: .incremental, fetched: 0, deleted: 0, relabeled: 0))
        #expect(try store.messageCount() == 1)
    }

    @Test func expiredHistoryFallsBackToFullResyncAndPrunes() async throws {
        let api = FakeGmail()
        api.add("a"); api.add("b")
        let (engine, store) = try makeEngine(api)
        _ = try await engine.sync()

        api.remove("a")
        api.add("c")
        api.oldestValidHistory = Int.max   // 之前记录的 historyId 全部失效

        let summary = try await engine.sync()
        #expect(summary.mode == .full)
        #expect(try store.recent(limit: 10).map(\.id).sorted() == ["b", "c"])
        #expect(api.listCalls == 2)
    }

    @Test func forceFullIgnoresStoredHistoryId() async throws {
        let api = FakeGmail()
        api.add("a")
        let (engine, _) = try makeEngine(api)
        _ = try await engine.sync()
        let summary = try await engine.sync(forceFull: true)
        #expect(summary.mode == .full)
        #expect(api.historyCalls == 0)
    }

    @Test func interruptedFullSyncResumesWithoutRefetchingAndCatchesUpOnNextIncremental() async throws {
        let api = FakeGmail()
        for i in 1...8 { api.add("m\(i)") }
        let startHistory = api.historyId
        let (engine, store) = try makeEngine(api)

        api.failMessageCallsAfter = 4
        await #expect(throws: MailError.self) { try await engine.sync() }
        let savedBeforeResume = try store.messageCount()
        #expect(savedBeforeResume >= 1 && savedBeforeResume < 8)
        #expect(store.historyId == nil)   // 没完成，不能当作已同步

        // 失败期间邮箱里又来了一封新邮件、并给已拉到的邮件改了标签
        api.add("late")
        api.removeLabel("UNREAD", from: "m1")

        api.stopFailing()
        let callsBefore = api.calls
        let resumed = try await engine.sync()
        #expect(resumed.mode == .full)
        #expect(api.calls - callsBefore == 8 - savedBeforeResume + 1)   // 只拉缺的（含 late），不重拉已有的
        #expect(store.historyId == startHistory)                         // 沿用最早的起点

        // 下一次增量从起点重放，补齐 late 的标签变化
        let catchUp = try await engine.sync()
        #expect(catchUp.mode == .incremental)
        #expect(try store.labelIds(of: "m1") == ["INBOX"])
        #expect(try store.messageCount() == 9)
        #expect(store.historyId == api.historyId)
    }

    @Test func loadOlderFetchesOnlyMissingMessagesAndLeavesHistoryAlone() async throws {
        let api = FakeGmail()
        for i in 1...10 { api.add("m\(i)", date: Int64(i) * 1000) }
        let (engine, store) = try makeEngine(api, limit: 4)
        _ = try await engine.sync()
        #expect(try store.messageCount() == 4)
        let historyBefore = store.historyId
        let callsBefore = api.calls

        let fetched = try await engine.loadOlder(limit: 8)
        #expect(fetched == 4)                                  // 8 封里已有 4 封，只补缺的
        #expect(api.calls - callsBefore == 4)
        #expect(try store.messageCount() == 8)
        #expect(store.historyId == historyBefore)              // 同步位置不变
        #expect(try await engine.loadOlder(limit: 8) == 0)     // 再来一次没有新的
    }

    @Test func messageDeletedBetweenListAndFetchIsSkipped() async throws {
        let api = FakeGmail()
        api.add("a"); api.add("b")
        let (engine, store) = try makeEngine(api)
        _ = try await engine.sync()

        api.add("x")
        api.remove("x")   // 同一批 history 里先加后删，不应拉取
        let summary = try await engine.sync()
        #expect(summary.fetched == 0)
        #expect(summary.deleted == 1)
        #expect(try store.messageCount() == 2)
    }
}
