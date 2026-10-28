import Foundation
import GRDB

// 本地改了、还没被 Gmail 确认的已读 / 未读（发件箱）。
//
// 标已读的流程：同一个事务里改本地状态 + 记一条待发送 → 请求 Gmail → 成功后删掉这条记录。
// 同步时 Gmail 那边可能还是旧状态（请求还在路上，或者上次没发出去），同步写完后用这里的记录把本地状态盖回来，
// 所以本地改动永远不会被同步冲掉；没发出去的下次同步前会重发。

extension MailStore {
    static func registerPendingMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15-pending-read") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pending_read (
                    messageId TEXT PRIMARY KEY,
                    unread INTEGER NOT NULL,
                    createdAt REAL NOT NULL
                )
                """)
        }
    }

    private static func setUnread(_ db: Database, messageId: String, unread: Bool) throws {
        try db.execute(sql: "UPDATE message SET isUnread = ? WHERE id = ?", arguments: [unread, messageId])
        if unread {
            try db.execute(sql: "INSERT OR IGNORE INTO message_label (messageId, labelId) VALUES (?, 'UNREAD')", arguments: [messageId])
        } else {
            try db.execute(sql: "DELETE FROM message_label WHERE messageId = ? AND labelId = 'UNREAD'", arguments: [messageId])
        }
    }

    /// 在一个事务里把这些邮件改成已读 / 未读并记为待发送。返回真正改了的（本地没有的、已经是目标状态的跳过）。
    func applyLocalRead(_ ids: [String], read: Bool, now: Date = Date()) throws -> [String] {
        try db.write { db in
            var changed: [String] = []
            for id in ids {
                guard let unread = try Bool.fetchOne(db, sql: "SELECT isUnread FROM message WHERE id = ?", arguments: [id]),
                      unread == read else { continue }
                try Self.setUnread(db, messageId: id, unread: !read)
                try db.execute(sql: "INSERT OR REPLACE INTO pending_read (messageId, unread, createdAt) VALUES (?, ?, ?)",
                               arguments: [id, !read, now.timeIntervalSince1970])
                changed.append(id)
            }
            return changed
        }
    }

    /// Gmail 确认了：删掉待发送记录（期间又被改成相反状态的保留）。
    func clearPendingRead(_ ids: [String], read: Bool) throws {
        try db.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM pending_read WHERE messageId = ? AND unread = ?", arguments: [id, !read])
            }
        }
    }

    /// Gmail 明确拒绝（授权不够等）：恢复原状态并丢掉待发送记录。
    func revertPendingRead(_ ids: [String], read: Bool) throws {
        try db.write { db in
            for id in ids {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pending_read WHERE messageId = ? AND unread = ?)",
                                        arguments: [id, !read]) == true else { continue }
                try Self.setUnread(db, messageId: id, unread: read)
                try db.execute(sql: "DELETE FROM pending_read WHERE messageId = ?", arguments: [id])
            }
        }
    }

    /// 还没被 Gmail 确认的改动，按目标状态分组：read = true 是要标已读的。
    func pendingReads() throws -> [(read: Bool, ids: [String])] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT messageId, unread FROM pending_read ORDER BY createdAt")
            let grouped = Dictionary(grouping: rows) { !($0["unread"] as Bool) }
            return grouped.keys.sorted { $0 && !$1 }.map { read in (read, grouped[read]!.map { $0["messageId"] as String }) }
        }
    }

    /// 同步写完之后调用：把待发送的改动重新盖到本地（同步可能用 Gmail 的旧状态覆盖了它们）。返回盖回了几封。
    @discardableResult
    public func reapplyPendingReads() throws -> Int {
        try db.write { db in
            var fixed = 0
            for row in try Row.fetchAll(db, sql: """
                SELECT p.messageId, p.unread FROM pending_read p JOIN message m ON m.id = p.messageId WHERE m.isUnread != p.unread
                """) {
                try Self.setUnread(db, messageId: row["messageId"], unread: row["unread"])
                fixed += 1
            }
            return fixed
        }
    }
}
