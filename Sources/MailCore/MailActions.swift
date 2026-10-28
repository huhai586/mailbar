import Foundation

/// 对邮件的修改操作。目前只有标记已读 / 未读：先改本地（界面立刻变化），再同步到 Gmail，失败就回滚。
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
    /// onLocalChange 在本地状态改完、请求 Gmail 之前调用，界面可以据此立刻刷新。
    public func setRead(_ read: Bool, messageIds: [String], onLocalChange: (@Sendable () -> Void)? = nil) async throws {
        let before = try messageIds.compactMap { id -> (id: String, labels: Set<String>)? in
            // 本地没有这封邮件，或者已经是目标状态：跳过
            guard try store.hasMessage(id) else { return nil }
            let labels = try store.labelIds(of: id)
            let isUnread = labels.contains("UNREAD")
            return isUnread == read ? (id, labels) : nil
        }
        guard !before.isEmpty else { return }

        for item in before {
            var labels = item.labels
            if read { labels.remove("UNREAD") } else { labels.insert("UNREAD") }
            try store.setLabels(messageId: item.id, labelIds: Array(labels))
        }
        onLocalChange?()
        do {
            try await api.batchModify(ids: before.map(\.id),
                                      addLabelIds: read ? [] : ["UNREAD"],
                                      removeLabelIds: read ? ["UNREAD"] : [])
        } catch {
            for item in before { try? store.setLabels(messageId: item.id, labelIds: Array(item.labels)) }
            throw error
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
