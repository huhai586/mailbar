import MailCore
import SwiftUI

/// 助理的「主动」部分：每分钟看一眼——到点的提醒、每天的自动简报、等你太久的事。
extension MailService {
    func startAssistantLoop() {
        assistantTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.assistantTick()
            }
        }
    }

    func assistantTick(now: Date = Date()) async {
        checkCalendarReminders(now: now)
        // 待办和跟进提醒按账号各看各的邮件库；每天的简报只针对当前账号，一天一份
        let config = AIConfigStore.read()
        let followUps = config.followUpHours > 0 && now.timeIntervalSince(lastFollowUpCheck) > 1800
        if followUps { lastFollowUpCheck = now }
        for session in allSessions {
            deliverDueReminders(store: session.store, accountID: session.id, now: now)
            if followUps { deliverFollowUps(store: session.store, accountID: session.id, now: now, hours: config.followUpHours) }
        }
        if config.briefAuto, let store { await autoBrief(store: store, config: config, now: now) }
    }

    private func deliverDueReminders(store: MailStore, accountID: String, now: Date) {
        guard let due = try? store.dueReminders(now: now), !due.isEmpty else { return }
        for todo in due {
            notifier.post(id: "todo-\(todo.id)", title: "提醒", body: todo.text, threadId: todo.groupKey, useDefaultSound: true, accountID: accountID)
            try? store.markTodoNotified(todo.id)
        }
        bumpTodos()
    }

    private func deliverFollowUps(store: MailStore, accountID: String, now: Date, hours: Int) {
        guard Pref.alertsOn,
              let stale = try? FollowUps.collect(store: store, now: now, olderThan: TimeInterval(hours) * 3600),
              !stale.isEmpty else { return }
        let titles = stale.prefix(3).map { $0.prSubject ?? $0.subject }.joined(separator: "\n")
        notifier.post(id: "followup-\(UUID().uuidString)", title: "\(stale.count) 件事等你超过 \(hours) 小时", body: titles,
                      threadId: stale.count == 1 ? stale[0].id : nil, useDefaultSound: true, accountID: accountID)
    }

    private func autoBrief(store: MailStore, config: AIConfig, now: Date) async {
        let calendar = Calendar.current
        guard let target = calendar.date(bySettingHour: config.briefHour, minute: config.briefMinute, second: 0, of: now),
              now >= target, BriefCache.load() == nil,
              now.timeIntervalSince(lastBriefAttempt) > 1800,      // 失败了也别每分钟重试
              let assistant = AIRuntime.assistant(store: store, githubLogin: nil) else { return }
        lastBriefAttempt = now
        do {
            let text = try await assistant.brief(tools: StoreMailTools(store: store))
            BriefCache.save(text)
            bumpBrief()
            notifier.post(id: "brief-\(BriefCache.today)", title: "今日简报", body: Self.notificationPreview(of: text),
                          threadId: nil, useDefaultSound: true)
        } catch {
            trace("[Brief] 自动简报失败：%@", error.localizedDescription)
        }
    }

    /// 通知里显示简报的开头：去掉 Markdown 标记，取前几行。
    static func notificationPreview(of markdown: String) -> String {
        let lines = markdown.split(whereSeparator: \.isNewline)
            .map { $0.drop(while: { "#-* ".contains($0) }).replacingOccurrences(of: "`", with: "") }
            .filter { !$0.isEmpty }
        return String(lines.prefix(3).joined(separator: "\n").prefix(200))
    }
}
