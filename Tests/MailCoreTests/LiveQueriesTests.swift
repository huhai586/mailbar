import Foundation
import Testing
@testable import MailCore

@MainActor
@Suite struct LiveQueriesTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<60 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func store() throws -> MailStore {
        let store = try MailStore(path: nil)
        try store.upsert([
            makeMessage("old", subject: "old", date: 1_000, labels: ["INBOX", "UNREAD"], thread: "T1"),
            makeMessage("new", subject: "new", date: 2_000, labels: ["INBOX", "UNREAD"], thread: "T2"),
        ])
        return store
    }

    @Test func listDeliversFirstResultImmediatelyAndUpdatesInPlaceAfterMarkingRead() async throws {
        let store = try store()
        var snapshots: [ListSnapshot] = []
        let observation = store.observeList(ThreadQuery(mailbox: .allMail, groupByPR: false, limit: 10)) { snapshots.append($0) }
        defer { observation.cancel() }
        #expect(snapshots.count == 1)                                          // 同步拿到第一次结果
        #expect(snapshots[0].threads.map(\.id) == ["T2", "T1"])

        _ = try store.applyLocalRead(["old"], read: true)
        try await waitUntil { snapshots.count >= 2 }
        let latest = try #require(snapshots.last)
        #expect(latest.threads.map(\.id) == ["T2", "T1"])                      // 顺序不变
        #expect(latest.threads.map(\.isUnread) == [true, false])               // 原地变成已读
    }

    @Test func pagingAndSourceCountsComeWithTheList() throws {
        let store = try store()
        var snapshot: ListSnapshot?
        let observation = store.observeList(ThreadQuery(mailbox: .allMail, groupByPR: false, limit: 1)) { snapshot = $0 }
        defer { observation.cancel() }
        #expect(snapshot?.threads.map(\.id) == ["T2"])
        #expect(snapshot?.hasMore == true)
        #expect(snapshot?.sourceCounts["other"]?.groups == 2)
    }

    @Test func detailUpdatesWhenItsMessagesChange() async throws {
        let store = try store()
        var versions: [[MessageDetail]] = []
        let observation = store.observeMessages(inGroup: "T1") { versions.append($0) }
        defer { observation.cancel() }
        #expect(versions.first?.map(\.isUnread) == [true])

        _ = try store.applyLocalRead(["new"], read: true)                      // 别的分组的改动：结果不变就不回调
        _ = try store.applyLocalRead(["old"], read: true)
        try await waitUntil { versions.count >= 2 }
        #expect(versions.count == 2)
        #expect(versions.last?.map(\.isUnread) == [false])
    }

    @Test func cancelledObservationsStopUpdating() async throws {
        let store = try store()
        var count = 0
        let observation = store.observeMessages(inGroup: "T1") { _ in count += 1 }
        observation.cancel()
        _ = try store.applyLocalRead(["old"], read: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(count == 1)
    }
}
