import Foundation
import GRDB

// 界面直接订阅数据库：查询涉及的表一有写入（同步、标已读……），就在后台重新查询，结果有变化才回调到主线程。
// 列表和详情都从这里拿数据，同一次写入之后两边看到的是同一个状态，不再靠手动"刷新计数"去通知。

/// 列表的查询条件。
public struct ThreadQuery: Equatable, Sendable {
    public var mailbox: Mailbox
    public var search: String
    public var unreadOnly: Bool
    public var source: String?
    public var groupByPR: Bool
    public var limit: Int

    public init(mailbox: Mailbox, search: String = "", unreadOnly: Bool = false, source: String? = nil, groupByPR: Bool, limit: Int) {
        self.mailbox = mailbox
        self.search = search
        self.unreadOnly = unreadOnly
        self.source = source
        self.groupByPR = groupByPR
        self.limit = limit
    }
}

/// 一次列表查询的结果。
public struct ListSnapshot: Equatable, Sendable {
    public let threads: [ThreadSummary]
    /// 后面还有没有（多取了一条来判断）
    public let hasMore: Bool
    /// 各来源的分组数（列表顶部的分类标签）
    public let sourceCounts: [String: SourceCount]
}

/// 一个正在进行的订阅；释放或 cancel() 后停止。
public final class StoreObservation {
    private let cancellable: AnyDatabaseCancellable

    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = cancellable
    }

    public func cancel() { cancellable.cancel() }
}

extension MailStore {
    /// 订阅列表。第一次结果在调用时同步返回（切换邮箱时不闪一下空白），之后每次变化在主线程回调。
    @MainActor
    public func observeList(_ query: ThreadQuery, onError: @escaping @MainActor (Error) -> Void = { _ in },
                            onChange: @escaping @MainActor (ListSnapshot) -> Void) -> StoreObservation {
        let observation = ValueObservation.tracking { db -> ListSnapshot in
            let search = query.search.isEmpty ? nil : query.search
            let rows = try Self.fetchThreads(db, in: query.mailbox, search: search, unreadOnly: query.unreadOnly, source: query.source,
                                             groupByPR: query.groupByPR, limit: query.limit + 1, offset: 0)
            let counts = try Self.fetchSourceCounts(db, in: query.mailbox, search: search, groupByPR: query.groupByPR)
            return ListSnapshot(threads: Array(rows.prefix(query.limit)), hasMore: rows.count > query.limit, sourceCounts: counts)
        }.removeDuplicates()
        return start(observation, onError: onError, onChange: onChange)
    }

    /// 订阅一个分组（PR 或会话）里的邮件，旧的在前。
    @MainActor
    public func observeMessages(inGroup id: String, onError: @escaping @MainActor (Error) -> Void = { _ in },
                                onChange: @escaping @MainActor ([MessageDetail]) -> Void) -> StoreObservation {
        let observation = ValueObservation.tracking { db in try Self.fetchMessages(db, inGroup: id) }.removeDuplicates()
        return start(observation, onError: onError, onChange: onChange)
    }

    @MainActor
    private func start<Value: Sendable>(_ observation: ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<Value>>>,
                                        onError: @escaping @MainActor (Error) -> Void,
                                        onChange: @escaping @MainActor (Value) -> Void) -> StoreObservation {
        let cancellable = observation.start(in: db, scheduling: .immediate,
                                            onError: { error in MainActor.assumeIsolated { onError(error) } },
                                            onChange: { value in MainActor.assumeIsolated { onChange(value) } })
        return StoreObservation(cancellable)
    }
}
