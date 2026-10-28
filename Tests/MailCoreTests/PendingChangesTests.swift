import Foundation
import Testing
@testable import MailCore

@Suite struct PendingChangesTests {
    private func setup(_ ids: [String] = ["a"]) async throws -> (FakeGmail, MailStore, MailActions, SyncEngine) {
        let api = FakeGmail()
        for id in ids { api.add(id, labels: ["INBOX", "UNREAD"]) }
        let store = try MailStore(path: nil)
        let engine = SyncEngine(api: api, store: store, initialLimit: 100, log: { _ in })
        _ = try await engine.sync()
        return (api, store, MailActions(api: api, store: store), engine)
    }

    private func isUnread(_ store: MailStore, _ id: String) throws -> Bool {
        try store.labelIds(of: id).contains("UNREAD")
    }

    @Test func setReadReportsOnlyTheMessagesThatActuallyChanged() async throws {
        let (api, store, actions, _) = try await setup(["a", "b", "c"])
        _ = api
        try store.setLabels(messageId: "b", labelIds: ["INBOX"])          // b 本来就是已读
        let changed = try await actions.setRead(true, messageIds: ["a", "b", "c"])
        #expect(Set(changed) == ["a", "c"])                               // 撤销时只该恢复这两封
        #expect(try await actions.setRead(true, messageIds: ["a", "b", "c"]).isEmpty)
        let undone = try await actions.setRead(false, messageIds: changed)
        #expect(Set(undone) == ["a", "c"])
        #expect(try isUnread(store, "a") && isUnread(store, "c") && !isUnread(store, "b"))
    }

    @Test func networkFailureKeepsTheLocalChangeAndRetriesLater() async throws {
        let (api, store, actions, _) = try await setup()
        api.batchModifyError = URLError(.notConnectedToInternet)
        try await actions.setRead(true, messageIds: ["a"])          // 临时失败不抛错
        #expect(try !isUnread(store, "a"))
        #expect(try store.pendingReads().map(\.ids) == [["a"]])

        api.batchModifyError = nil
        try await actions.flushPending()
        #expect(api.batchCalls.map(\.ids) == [["a"]])
        #expect(try store.pendingReads().isEmpty)
        #expect(try !isUnread(store, "a"))
    }

    @Test func syncCannotUndoAChangeGmailHasNotConfirmed() async throws {
        let (api, store, actions, _) = try await setup()
        api.batchModifyError = URLError(.timedOut)
        try await actions.setRead(true, messageIds: ["a"])
        // 同步用 Gmail 的旧状态（还是未读）盖了本地
        try store.setLabels(messageId: "a", labelIds: ["INBOX", "UNREAD"])
        #expect(try store.reapplyPendingReads() == 1)
        #expect(try !isUnread(store, "a"))
        #expect(try store.reapplyPendingReads() == 0)
    }

    @Test func confirmedChangesLeaveNothingPending() async throws {
        let (api, store, actions, engine) = try await setup()
        try await actions.setRead(true, messageIds: ["a"])
        #expect(try store.pendingReads().isEmpty)
        _ = try await engine.sync()
        #expect(try !isUnread(store, "a"))
        #expect(api.batchCalls.count == 1)
    }

    @Test func laterOppositeChangeWins() async throws {
        let (api, store, actions, _) = try await setup()
        api.batchModifyError = URLError(.timedOut)
        try await actions.setRead(true, messageIds: ["a"])           // 挂着「标已读」
        api.batchModifyError = nil
        try await actions.setRead(false, messageIds: ["a"])          // 又标回未读，成功
        #expect(try isUnread(store, "a"))
        #expect(try store.pendingReads().isEmpty)
        try await actions.flushPending()
        #expect(api.batchCalls.map(\.add) == [["UNREAD"]])           // 旧的「标已读」不会再发
    }

    @Test func permanentRejectionRevertsButRateLimitIsRetried() async throws {
        let (api, store, actions, _) = try await setup(["a", "b"])
        api.batchModifyError = MailError.http(status: 400, body: "bad")
        await #expect(throws: MailError.self) { try await actions.setRead(true, messageIds: ["a"]) }
        #expect(try isUnread(store, "a") && store.pendingReads().isEmpty)

        api.batchModifyError = MailError.http(status: 429, body: "slow down")
        try await actions.setRead(true, messageIds: ["b"])
        #expect(try !isUnread(store, "b"))
        #expect(try store.pendingReads().map(\.ids) == [["b"]])
    }

    @Test func monitorReappliesPendingChangesAfterEverySync() async throws {
        let api = FakeGmail()
        api.add("a", labels: ["INBOX", "UNREAD"])
        let store = try MailStore(path: nil)
        let rulesPath = NSTemporaryDirectory() + "pending-\(UUID().uuidString).json"
        try Data(#"{"rules":[]}"#.utf8).write(to: URL(fileURLWithPath: rulesPath))
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let monitor = MailMonitor(api: api, store: store, rulesPath: rulesPath)
        _ = try await monitor.syncOnce()

        api.batchModifyError = URLError(.timedOut)
        try await MailActions(api: api, store: store).setRead(true, messageIds: ["a"])
        try store.setLabels(messageId: "a", labelIds: ["INBOX", "UNREAD"])   // 模拟同步写回旧状态
        _ = try await monitor.syncOnce()
        #expect(try !isUnread(store, "a"))
    }
}
