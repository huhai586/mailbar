import Testing
@testable import MailCore

private func ref(_ id: String, labels: [String]? = nil) -> HistoryRecord.Change {
    HistoryRecord.Change(message: GmailMessageRef(id: id, threadId: "t", labelIds: labels), labelIds: nil)
}

private func record(added: [String] = [], deleted: [String] = [],
                    labelsAdded: [(String, [String])] = [], labelsRemoved: [(String, [String])] = []) -> HistoryRecord {
    HistoryRecord(id: "1",
                  messagesAdded: added.map { ref($0) },
                  messagesDeleted: deleted.map { ref($0) },
                  labelsAdded: labelsAdded.map { ref($0.0, labels: $0.1) },
                  labelsRemoved: labelsRemoved.map { ref($0.0, labels: $0.1) })
}

@Suite struct HistoryReducerTests {
    @Test func addedAreFetchedInOrderWithoutDuplicates() {
        let plan = HistoryReducer.reduce([record(added: ["a", "b"]), record(added: ["b", "c"])])
        #expect(plan.toFetch == ["a", "b", "c"])
    }

    @Test func addThenDeleteCancelsFetch() {
        let plan = HistoryReducer.reduce([record(added: ["a"]), record(deleted: ["a"])])
        #expect(plan.toFetch.isEmpty)
        #expect(plan.toDelete == ["a"])
    }

    @Test func deleteThenAddRestoresFetch() {
        let plan = HistoryReducer.reduce([record(deleted: ["a"]), record(added: ["a"])])
        #expect(plan.toFetch == ["a"])
        #expect(plan.toDelete.isEmpty)
    }

    @Test func lastLabelStateWins() {
        let plan = HistoryReducer.reduce([
            record(labelsAdded: [("a", ["INBOX", "UNREAD"])]),
            record(labelsRemoved: [("a", ["INBOX"])]),
        ])
        #expect(plan.labelUpdates == ["a": ["INBOX"]])
    }

    @Test func labelChangesIgnoredForFetchedOrDeletedMessages() {
        let plan = HistoryReducer.reduce([
            record(added: ["new"]), record(labelsAdded: [("new", ["INBOX"])]),
            record(deleted: ["gone"]), record(labelsAdded: [("gone", ["INBOX"])]),
        ])
        #expect(plan.labelUpdates.isEmpty)
    }

    @Test func deleteDropsEarlierLabelUpdate() {
        let plan = HistoryReducer.reduce([record(labelsAdded: [("a", ["STARRED"])]), record(deleted: ["a"])])
        #expect(plan.labelUpdates.isEmpty)
        #expect(plan.toDelete == ["a"])
    }

    @Test func emptyHistory() {
        #expect(HistoryReducer.reduce([]).isEmpty)
    }
}
