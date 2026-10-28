import Foundation

/// 对邮件的修改操作。目前只有标记已读 / 未读：先改本地并记为待发送（界面立刻变化），再同步到 Gmail（见 PendingChanges.swift）。
public final class MailActions: Sendable {
    private let api: any GmailAPI
    private let store: MailStore

    init(api: any GmailAPI, store: MailStore) {
        self.api = api
        self.store = store
    }

    public convenience init(oauth: OAuthClient, store: MailStore) {
        self.init(api: GmailClient(oauth: oauth), store: store)
    }

    /// 只改本地、不碰 Gmail：排查界面问题时在邮件库的副本上复现用（App 里由 MAIL_FAKE_REMOTE 开启）。
    public convenience init(localOnlyStore store: MailStore) {
        self.init(api: LocalOnlyGmail(), store: store)
    }

    /// 把这些邮件标为已读（read = true）或未读。已经是目标状态的会被跳过；全部跳过时不发请求。
    /// 先在本地改好并记为待发送（onLocalChange 在这之后、请求 Gmail 之前调用，界面立刻变化），再同步到 Gmail：
    /// - 成功：清掉待发送记录；
    /// - Gmail 明确拒绝（授权不够、请求无效）：恢复原状态并抛错；
    /// - 网络问题等临时失败：保留本地状态和待发送记录，下次同步前由 flushPending() 重发，不抛错。
    public func setRead(_ read: Bool, messageIds: [String], onLocalChange: (@Sendable () -> Void)? = nil) async throws {
        let changed = try store.applyLocalRead(messageIds, read: read)
        guard !changed.isEmpty else { return }
        onLocalChange?()
        try await push(changed, read: read)
    }

    /// 重发还没被 Gmail 确认的改动（上次网络失败、或者请求发出前应用退出了）。
    public func flushPending() async throws {
        for group in try store.pendingReads() {
            try await push(group.ids, read: group.read)
        }
    }

    private func push(_ ids: [String], read: Bool) async throws {
        do {
            try await api.batchModify(ids: ids, addLabelIds: read ? [] : ["UNREAD"], removeLabelIds: read ? ["UNREAD"] : [])
            try store.clearPendingRead(ids, read: read)
        } catch {
            guard Self.isPermanent(error) else { return }    // 临时失败：留着下次重发
            try? store.revertPendingRead(ids, read: read)
            throw error
        }
    }

    /// 重试也没用的失败：授权问题、请求本身无效（4xx，限流 429 除外）。
    static func isPermanent(_ error: Error) -> Bool {
        switch error {
        case MailError.reauthorizationRequired, MailError.loginRequired: return true
        case MailError.http(let status, _): return (400..<500).contains(status) && status != 429
        default: return false
        }
    }
}

private struct LocalOnlyGmail: GmailAPI {
    func profile() async throws -> GmailProfile { throw MailError.loginRequired }
    func labels() async throws -> [GmailLabel] { throw MailError.loginRequired }
    func listMessageIDs(limit: Int) async throws -> [String] { throw MailError.loginRequired }
    func message(id: String) async throws -> GmailMessage? { throw MailError.loginRequired }
    func history(since startHistoryId: String) async throws -> (records: [HistoryRecord], historyId: String?) { throw MailError.loginRequired }
    func batchModify(ids: [String], addLabelIds: [String], removeLabelIds: [String]) async throws {}
    func reasonHeader(id: String) async throws -> String? { throw MailError.loginRequired }
}
