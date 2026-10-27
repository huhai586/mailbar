import Foundation
import Testing
@testable import MailCore

@Suite struct MailActionsTests {
    private func setup(_ messages: [(id: String, labels: [String])]) async throws -> (FakeGmail, MailStore, MailActions) {
        let api = FakeGmail()
        for m in messages { api.add(m.id, labels: m.labels) }
        let store = try MailStore(path: nil)
        _ = try await SyncEngine(api: api, store: store, initialLimit: 100, log: { _ in }).sync()
        return (api, store, MailActions(api: api, store: store))
    }

    @Test func markReadUpdatesLocalStateAndGmail() async throws {
        let (api, store, actions) = try await setup([("a", ["INBOX", "UNREAD"]), ("b", ["INBOX", "UNREAD"])])
        try await actions.setRead(true, messageIds: ["a"])
        #expect(try store.labelIds(of: "a") == ["INBOX"])
        #expect(try store.labelIds(of: "b") == ["INBOX", "UNREAD"])
        #expect(api.batchCalls.count == 1)
        #expect(api.batchCalls[0].ids == ["a"] && api.batchCalls[0].remove == ["UNREAD"] && api.batchCalls[0].add.isEmpty)
        #expect(try store.recent(limit: 10).first { $0.id == "a" }?.isUnread == false)
    }

    @Test func markUnreadAddsTheLabelBack() async throws {
        let (api, store, actions) = try await setup([("a", ["INBOX"])])
        try await actions.setRead(false, messageIds: ["a"])
        #expect(try store.labelIds(of: "a") == ["INBOX", "UNREAD"])
        #expect(api.batchCalls.first?.add == ["UNREAD"])
    }

    @Test func alreadyInTargetStateOrUnknownMessagesAreSkippedWithoutARequest() async throws {
        let (api, _, actions) = try await setup([("read", ["INBOX"]), ("unread", ["INBOX", "UNREAD"])])
        try await actions.setRead(true, messageIds: ["read", "missing"])
        #expect(api.batchCalls.isEmpty)
        try await actions.setRead(true, messageIds: ["read", "unread"])
        #expect(api.batchCalls.first?.ids == ["unread"])      // 只发需要改的
    }

    @Test func failureRollsLocalStateBack() async throws {
        let (api, store, actions) = try await setup([("a", ["INBOX", "UNREAD"])])
        api.batchModifyError = MailError.reauthorizationRequired
        await #expect(throws: MailError.self) { try await actions.setRead(true, messageIds: ["a"]) }
        #expect(try store.labelIds(of: "a") == ["INBOX", "UNREAD"])    // 回滚
        #expect(try store.recent(limit: 1).first?.isUnread == true)
    }

    @Test func nextIncrementalSyncAgreesWithTheOptimisticLocalChange() async throws {
        let api = FakeGmail()
        api.add("a", labels: ["INBOX", "UNREAD"])
        let store = try MailStore(path: nil)
        let engine = SyncEngine(api: api, store: store, initialLimit: 100, log: { _ in })
        _ = try await engine.sync()
        try await MailActions(api: api, store: store).setRead(true, messageIds: ["a"])
        _ = try await engine.sync()          // 重放 history 里的 labelsRemoved
        #expect(try store.labelIds(of: "a") == ["INBOX"])
    }
}

@Suite struct StoredTokenTests {
    @Test func tokensSavedBeforeScopeTrackingAreTreatedAsReadOnly() throws {
        let old = #"{"accessToken":"a","refreshToken":"r","expiry":0}"#
        let token = try JSONDecoder().decode(StoredToken.self, from: Data(old.utf8))
        #expect(token.scope == nil && !token.canModify)
    }

    @Test func modifyScopeIsDetected() throws {
        var token = StoredToken(accessToken: "a", refreshToken: "r", expiry: Date(),
                                scope: "https://www.googleapis.com/auth/gmail.readonly")
        #expect(!token.canModify)
        token.scope = "https://www.googleapis.com/auth/gmail.modify"
        #expect(token.canModify)
    }
}

@Suite struct RulePreviewTests {
    @Test func countsAllMatchesAndReturnsNewestSamples() throws {
        let store = try MailStore(path: nil)
        try store.upsert((1...30).map { makeMessage("m\($0)", subject: $0 % 2 == 0 ? "告警 \($0)" : "hello \($0)", date: Int64($0) * 1000) })
        let preview = try store.preview(rule: Rule(name: "t", enabled: false, keywords: ["告警"]), sampleLimit: 3)
        #expect(preview.matchCount == 15)                                   // 禁用的规则也能试匹配
        #expect(preview.samples.map(\.id) == ["m30", "m28", "m26"])
    }

    @Test func noMatchesAndInvalidRegexGiveZero() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("a", subject: "x")])
        #expect(try store.preview(rule: Rule(name: "t", keywords: ["zzz"])).matchCount == 0)
        #expect(try store.preview(rule: Rule(name: "t", keywords: ["("], regex: true)).matchCount == 0)
    }
}
