import Foundation

/// 把一串按时间排序的 history 记录折叠成"要拉取 / 要删除 / 要更新标签"三类动作。
struct HistoryPlan: Equatable {
    var toFetch: [String] = []
    var toDelete: Set<String> = []
    var labelUpdates: [String: [String]] = [:]

    var isEmpty: Bool { toFetch.isEmpty && toDelete.isEmpty && labelUpdates.isEmpty }
}

enum HistoryReducer {
    static func reduce(_ records: [HistoryRecord]) -> HistoryPlan {
        var plan = HistoryPlan()
        var fetchSet = Set<String>()

        for record in records {
            for change in record.messagesAdded ?? [] {
                let id = change.message.id
                plan.toDelete.remove(id)
                plan.labelUpdates[id] = nil
                if fetchSet.insert(id).inserted { plan.toFetch.append(id) }
            }
            for change in record.messagesDeleted ?? [] {
                let id = change.message.id
                plan.toDelete.insert(id)
                plan.labelUpdates[id] = nil
                if fetchSet.remove(id) != nil { plan.toFetch.removeAll { $0 == id } }
            }
            // 已排队拉取的邮件会带回最新标签；已删除的无需更新
            for change in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                let id = change.message.id
                guard !fetchSet.contains(id), !plan.toDelete.contains(id), let labels = change.message.labelIds else { continue }
                plan.labelUpdates[id] = labels
            }
        }
        return plan
    }
}
