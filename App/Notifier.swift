import AppKit
import MailCore
import os
import UserNotifications

private let log = Logger(subsystem: "com.huhai.mailbar", category: "notify")

/// 在 Gmail 网页里打开某个会话（读不到本地内容、或想回复时用）。
func gmailURL(threadId: String?, account: String?) -> URL {
    var string = "https://mail.google.com/mail/"
    if let account, let encoded = account.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        string += "?authuser=\(encoded)"
    }
    string += threadId.map { "#all/\($0)" } ?? "#inbox"
    return URL(string: string) ?? URL(string: "https://mail.google.com/")!
}

/// 发系统通知；自定义声音由 SoundLibrary 单独播放，通知本身静音。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// 点击通知时调用，参数是要打开的会话（合并通知为 nil，只打开窗口）
    var onOpenThread: (@MainActor (String?) -> Void)?
    /// 强提醒的命中交给置顶卡片处理
    var onStrongHits: (@MainActor ([RuleHit]) -> Void)?

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            log.info("notification authorization granted=\(granted) error=\(error?.localizedDescription ?? "-")")
        }
    }

    /// 规则没指定声音时用设置里的默认提示音：空 = 系统默认通知音
    private func effectiveSound(_ hit: RuleHit) -> String? {
        if let sound = hit.sound { return sound }
        let fallback = Pref.defaultSoundName
        return fallback.isEmpty ? nil : fallback
    }

    func deliver(_ hits: [RuleHit], account: String?) {
        guard !hits.isEmpty else { return }

        let strong = hits.filter(\.strong)
        let normal = hits.filter { !$0.strong }

        // 强提醒：置顶卡片负责响铃和跳动；系统通知照发，留在通知中心里备查
        if !strong.isEmpty {
            Task { @MainActor in self.onStrongHits?(strong) }
            for hit in strong { postHit(hit, useDefaultSound: false) }
        }

        var played = Set<String>()
        for hit in normal {
            if let sound = effectiveSound(hit), sound.lowercased() != "none", played.insert(sound).inserted {
                SoundLibrary.play(sound)
            }
        }
        if normal.count > Pref.summaryThresholdCount {
            let subjects = normal.prefix(3).map(\.subject).joined(separator: "\n")
            post(id: "summary-\(UUID().uuidString)", title: "\(normal.count) 封邮件命中提醒规则", body: subjects,
                 threadId: nil, useDefaultSound: normal.contains { effectiveSound($0) == nil })
            return
        }
        for hit in normal { postHit(hit, useDefaultSound: effectiveSound(hit) == nil) }
    }

    private func postHit(_ hit: RuleHit, useDefaultSound: Bool) {
        post(id: "\(hit.messageId)-\(hit.ruleName)", title: "【\(hit.ruleName)】\(MailAddress.parse(hit.from).displayName)",
             body: hit.subject, threadId: hit.threadId, useDefaultSound: useDefaultSound)
    }

    func post(id: String, title: String, body: String, threadId: String?, useDefaultSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = useDefaultSound ? .default : nil
        if let threadId { content.userInfo = ["threadId": threadId] }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { log.error("post failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let threadId = response.notification.request.content.userInfo["threadId"] as? String
        Task { @MainActor in self.onOpenThread?(threadId) }
        completionHandler()
    }
}
