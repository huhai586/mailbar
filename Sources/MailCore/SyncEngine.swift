import Foundation

public struct SyncSummary: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case full, incremental }

    public var mode: Mode
    public var fetched = 0
    public var deleted = 0
    public var relabeled = 0
}

public final class SyncEngine: Sendable {
    private let api: any GmailAPI
    private let store: MailStore
    private let initialLimit: Int
    private let concurrency: Int
    private let log: @Sendable (String) -> Void
    private let onStored: (@Sendable ([ParsedMessage], SyncSummary.Mode) throws -> Void)?

    /// onStored 在每一批邮件入库后调用（规则匹配用）；mode 说明这批来自全量还是增量同步。
    init(api: any GmailAPI, store: MailStore, initialLimit: Int = 500, concurrency: Int = 8,
         log: @escaping @Sendable (String) -> Void = { print($0) },
         onStored: (@Sendable ([ParsedMessage], SyncSummary.Mode) throws -> Void)? = nil) {
        self.api = api
        self.store = store
        self.initialLimit = initialLimit
        self.concurrency = concurrency
        self.log = log
        self.onStored = onStored
    }

    public convenience init(oauth: OAuthClient, store: MailStore, initialLimit: Int = 500) {
        self.init(api: GmailClient(oauth: oauth), store: store, initialLimit: initialLimit)
    }

    /// 首次或 forceFull 时全量同步，之后走增量；historyId 过期会自动退回全量。
    public func sync(forceFull: Bool = false) async throws -> SyncSummary {
        if forceFull {
            try store.removeState(Self.pendingKey)
        } else if let historyId = try store.state("historyId") {
            do {
                return try await incremental(since: historyId)
            } catch MailError.historyExpired {
                log("historyId 已过期，改为全量同步…")
                try store.removeState(Self.pendingKey)
            }
        }
        return try await full()
    }

    /// 把邮箱里最新的 limit 封中本地还没有的补拉下来（用于"加载更早的邮件"）。
    func loadOlder(limit: Int) async throws -> Int {
        let ids = try await api.listMessageIDs(limit: limit)
        let have = try store.existingIDs()
        let missing = ids.filter { !have.contains($0) }
        log("补拉历史邮件：\(missing.count) 封")
        return try await fetchAndStore(missing, mode: .full)
    }

    func backfillReasons(limit: Int) async throws -> Int {
        let ids = try store.messageIDsMissingReason(limit: limit)
        guard !ids.isEmpty else { return 0 }
        var reasons: [String: String] = [:]
        for id in ids {
            // 邮件已经不在 Gmail 里（nil）也记成 ""，不再重试
            reasons[id] = try await api.reasonHeader(id: id) ?? ""
        }
        try store.setReasons(reasons)
        return ids.count
    }

    // MARK: - Full

    private static let pendingKey = "pendingFullSyncHistoryId"

    /// 全量同步可以断点续传：起点 historyId 在第一次尝试时记下，之后沿用最早的那个，
    /// 续传时跳过已入库的邮件；完成后下一次增量会从起点重放变更，补上期间的标签变化和新邮件。
    private func full() async throws -> SyncSummary {
        let profile = try await api.profile()
        try store.replaceLabels(try await api.labels())

        let ids = try await api.listMessageIDs(limit: initialLimit)
        let resumedFrom = try store.state(Self.pendingKey)
        let startHistoryId = resumedFrom ?? profile.historyId
        try store.setState([Self.pendingKey: startHistoryId])

        let have = resumedFrom == nil ? [] : try store.existingIDs()
        let toFetch = ids.filter { !have.contains($0) }
        log("全量同步：共 \(ids.count) 封，需要拉取 \(toFetch.count) 封\(resumedFrom == nil ? "" : "（续传）")")

        var summary = SyncSummary(mode: .full)
        summary.fetched = try await fetchAndStore(toFetch, mode: .full)
        try store.deleteMessages(notIn: Set(ids))
        try store.setState(["email": profile.emailAddress, "historyId": startHistoryId])
        try store.removeState(Self.pendingKey)
        return summary
    }

    // MARK: - Incremental

    private func incremental(since startHistoryId: String) async throws -> SyncSummary {
        let (records, latest) = try await api.history(since: startHistoryId)
        let plan = HistoryReducer.reduce(records)

        var summary = SyncSummary(mode: .incremental)
        summary.fetched = try await fetchAndStore(plan.toFetch, mode: .incremental)
        try store.delete(ids: plan.toDelete)
        summary.deleted = plan.toDelete.count
        for (id, labels) in plan.labelUpdates {
            try store.setLabels(messageId: id, labelIds: labels)
        }
        summary.relabeled = plan.labelUpdates.count
        // 全部落库后才推进 historyId，中途失败下次会重来
        if let latest { try store.setState(["historyId": latest]) }
        return summary
    }

    // MARK: - Fetching

    /// 并发拉取并解析，按批写入数据库；返回成功入库的数量。
    private func fetchAndStore(_ ids: [String], mode: SyncSummary.Mode) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let api = self.api
        var stored = 0
        var batch: [ParsedMessage] = []

        do {
            try await withThrowingTaskGroup(of: ParsedMessage?.self) { group in
                var iterator = ids.makeIterator()
                for _ in 0..<concurrency {
                    guard let id = iterator.next() else { break }
                    group.addTask { try await api.message(id: id).map(ParsedMessage.init) }
                }
                while let result = try await group.next() {
                    if let id = iterator.next() {
                        group.addTask { try await api.message(id: id).map(ParsedMessage.init) }
                    }
                    if let message = result { batch.append(message) }
                    if batch.count >= 50 {
                        try store.upsert(batch)
                        try onStored?(batch, mode)
                        stored += batch.count
                        batch.removeAll()
                        log("  已入库 \(stored)/\(ids.count)")
                    }
                }
            }
        } catch {
            // 中途失败也把已拉到的存下来，续传时不必重拉
            if (try? store.upsert(batch)) != nil { try? onStored?(batch, mode) }
            throw error
        }
        if !batch.isEmpty {
            try store.upsert(batch)
            try onStored?(batch, mode)
            stored += batch.count
        }
        return stored
    }
}
