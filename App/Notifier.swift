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
    /// 应用自己的通知卡片（设置里选了「应用内卡片」时用它代替系统通知）
    var toasts: ToastCenter?
    /// 点击日程提醒时调用：打开日历模块
    var onOpenCalendar: (@MainActor () -> Void)?
    /// 点击通知时调用，参数是（账号 id，要打开的会话）；合并通知的会话为 nil，只打开窗口
    var onOpenThread: (@MainActor (String?, String?) -> Void)?
    /// 强提醒的命中交给置顶卡片处理
    var onStrongHits: (@MainActor ([RuleHit]) -> Void)?
    /// 通知上的 👍 / 👎：(账号 id, 邮件 id, 1 或 -1)。AI 判断的通知才有这两个按钮
    var onFeedback: (@MainActor (String?, String, Int) -> Void)?

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

    func deliver(_ hits: [RuleHit], account: String?, accountID: String? = nil) {
        guard !hits.isEmpty else { return }

        let strong = hits.filter(\.strong)
        let normal = hits.filter { !$0.strong }

        // 强提醒：置顶卡片负责响铃和跳动；系统通知照发，留在通知中心里备查
        if !strong.isEmpty {
            Task { @MainActor in self.onStrongHits?(strong) }
            for hit in strong { postHit(hit, useDefaultSound: false, accountID: accountID, forceSystem: true) }
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
                 threadId: nil, useDefaultSound: normal.contains { effectiveSound($0) == nil }, accountID: accountID)
            return
        }
        for hit in normal { postHit(hit, useDefaultSound: effectiveSound(hit) == nil, accountID: accountID) }
    }

    private func postHit(_ hit: RuleHit, useDefaultSound: Bool, accountID: String?, forceSystem: Bool = false) {
        // AI 判断过的（理由以「AI：」开头）系统通知上带 👍 / 👎 操作
        let judged = hit.snippet.hasPrefix("AI：")
        // 只有标题（邮件主题）和正文（邮件内容的前几十个字）；没有内容可显示时用发件人顶上
        let subject = hit.subject.trimmingCharacters(in: .whitespaces)
        var body = SnippetText.clip(hit.preview, to: Pref.notificationPreviewLimit)
        if body == subject { body = "" }
        if body.isEmpty { body = MailAddress.parse(hit.from).displayName }
        post(id: "\(hit.messageId)-\(hit.ruleName)", title: subject.isEmpty ? "（无主题）" : subject, body: body,
             threadId: hit.threadId, useDefaultSound: useDefaultSound,
             judgedMessageId: judged ? hit.messageId : nil, accountID: accountID, forceSystem: forceSystem)
    }

    func post(id: String, title: String, body: String, threadId: String?, useDefaultSound: Bool, judgedMessageId: String? = nil, accountID: String? = nil,
              forceSystem: Bool = false, calendar: Bool = false, joinURL: URL? = nil) {
        if Pref.useToastCards, !forceSystem, let toasts {
            // 应用内卡片：显示时长由设置决定；提示音这里自己播（系统通知才会自带）
            if useDefaultSound { SoundLibrary.play("Glass") }
            var item = ToastItem(kind: calendar ? .calendar : .mail, title: title, body: body)
            item.kind = calendar ? .calendar : .mail
            item.accountID = accountID
            item.threadId = threadId
            item.joinURL = joinURL
            item.judgedMessageId = judgedMessageId
            Task { @MainActor in toasts.show(item) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = useDefaultSound ? .default : nil
        var info: [String: String] = [:]
        if let threadId { info["threadId"] = threadId }
        if let accountID { info["account"] = accountID }
        if calendar { info["calendar"] = "1" }
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
        let accountID = info["account"] as? String
        if info["calendar"] as? String == "1" {
            Task { @MainActor in self.onOpenCalendar?() }
            completionHandler()
            return
        }
        switch response.actionIdentifier {
        case Self.usefulAction, Self.uselessAction:
            // 只记反馈，不打开应用
            if let messageId = info["messageId"] as? String {
                let value = response.actionIdentifier == Self.usefulAction ? 1 : -1
                Task { @MainActor in self.onFeedback?(accountID, messageId, value) }
            }
        default:
            Task { @MainActor in self.onOpenThread?(accountID, threadId) }
        }
        completionHandler()
    }
}
