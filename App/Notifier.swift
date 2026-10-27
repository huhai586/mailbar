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
    /// 通知上的 👍 / 👎：(邮件 id, 1 或 -1)。AI 判断的通知才有这两个按钮
    var onFeedback: (@MainActor (String, Int) -> Void)?

    private static let verdictCategory = "AI_VERDICT"
    private static let usefulAction = "AI_USEFUL"
    private static let uselessAction = "AI_USELESS"

    func start() {
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.verdictCategory,
            actions: [UNNotificationAction(identifier: Self.usefulAction, title: "👍 有用", options: []),
                      UNNotificationAction(identifier: Self.uselessAction, title: "👎 没用", options: [])],
            intentIdentifiers: [], options: [])])
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
        // AI 判断过的（理由以「AI：」开头）带上反馈按钮
        let judged = hit.snippet.hasPrefix("AI：")
        post(id: "\(hit.messageId)-\(hit.ruleName)", title: "【\(hit.ruleName)】\(MailAddress.parse(hit.from).displayName)",
             body: judged ? "\(hit.subject)\n\(hit.snippet)" : hit.subject, threadId: hit.threadId, useDefaultSound: useDefaultSound,
             judgedMessageId: judged ? hit.messageId : nil)
    }

    func post(id: String, title: String, body: String, threadId: String?, useDefaultSound: Bool, judgedMessageId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = useDefaultSound ? .default : nil
        var info: [String: String] = [:]
        if let threadId { info["threadId"] = threadId }
        if let judgedMessageId {
            info["messageId"] = judgedMessageId
            content.categoryIdentifier = Self.verdictCategory
        }
        content.userInfo = info
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
        let info = response.notification.request.content.userInfo
        let threadId = info["threadId"] as? String
        switch response.actionIdentifier {
        case Self.usefulAction, Self.uselessAction:
            // 只记反馈，不打开应用
            if let messageId = info["messageId"] as? String {
                let value = response.actionIdentifier == Self.usefulAction ? 1 : -1
                Task { @MainActor in self.onFeedback?(messageId, value) }
            }
        default:
            Task { @MainActor in self.onOpenThread?(threadId) }
        }
        completionHandler()
    }
}
