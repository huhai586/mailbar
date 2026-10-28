import Foundation
import MailCore

enum MarkReadMode: String, CaseIterable, Identifiable {
    case onOpen, afterDelay, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onOpen: return "打开后立即标为已读"
        case .afterDelay: return "打开一会儿后标为已读"
        case .manual: return "只手动标记"
        }
    }
}

/// 全部设置项的键和默认值。界面用 @AppStorage(Pref.xxx)，非界面代码用下面的计算属性读取。
enum Pref {
    // 外观
    static let appearance = "appearance"          // dark（终端）/ light（纸质）/ night / day / system
    static let listDensity = "listDensity"        // 旧的列表密度（已被 uiDensity 取代，保留键避免旧设置报错）
    static let uiDensity = "uiDensity"            // 整体密度：compact（紧凑）/ standard（标准）/ spacious（宽松）
    static let fontSet = "fontSet"                // 字体套装：jetbrains（默认）/ plex / system
    static let fontOffset = "fontOffset"          // 整体字号偏移（pt，相对默认大小，-3 … +6）
    static let monoBody = "monoBody"
    static let showSnippets = "showSnippets"
    static let landing = "landingMailbox"        // 启动时先看哪里：attention（待处理）/ inbox（收件箱）
    static let autoCleanRoutine = "autoCleanRoutine"  // 自动把例行机器人邮件标为已读
    static let groupByPR = "groupByPR"            // 列表按 PR 聚合（评论、CI、Jira 联动合成一行）
    static let newMailAlerts = "newMailAlerts"    // 没命中规则的新邮件要不要通知：all / important / off
    static let jiraName = "jiraName"              // 你在 Jira 里的显示名（@Howard Hu）；用来判断 Jira 邮件有没有提到你
    static let githubLogin = "githubLogin"        // 你的 GitHub 用户名；留空则自动识别
    static let sidebarShown = "sidebarShown"      // 侧栏显示哪些邮箱 / 标签（逗号分隔：UNREAD、ALL 或 Gmail 标签 id）
    // 通用
    static let pollInterval = "pollInterval"
    static let openWindowAtLaunch = "openWindowAtLaunch"
    // 阅读
    static let loadRemoteImages = "loadRemoteImages"
    static let renderMarkdown = "renderMarkdown"  // 渲染 Markdown（GitHub 评论、Markdown 格式的邮件）
    static let githubTextView = "githubTextView"  // GitHub 邮件默认显示纯文本
    static let invertEmails = "invertEmails"      // 深色模式下把 HTML 邮件反色"
    static let markReadMode = "markReadMode"
    static let markReadDelay = "markReadDelay"
    static let markReadWholeThread = "markReadWholeThread"
    // 提醒
    static let alertsEnabled = "alertsEnabled"
    static let alertMaxAgeHours = "alertMaxAgeHours"
    static let summaryThreshold = "summaryThreshold"
    static let defaultSound = "defaultSound"
    /// 通知的呈现方式：card = 应用自己的通知卡片（显示时长可调），system = macOS 系统通知（时长由系统决定）
    static let notificationStyle = "notificationStyle"
    static let toastSeconds = "toastSeconds"
    /// 通知里附带邮件正文的前多少个字（0 = 不附带）
    static let notificationPreviewChars = "notificationPreviewChars"
    // 日历提醒
    static let calendarReminders = "calendarReminders"
    static let calendarLeadMinutes = "calendarLeadMinutes"
    // 强提醒
    static let strongRepeatSeconds = "strongRepeatSeconds"
    static let strongMaxMinutes = "strongMaxMinutes"
    static let strongBounceDock = "strongBounceDock"
    static let strongSound = "strongSound"
    // 同步
    static let initialSyncLimit = "initialSyncLimit"
    static let loadOlderBatch = "loadOlderBatch"
    // 界面状态
    static let settingsTab = "settingsTab"
    /// 当前授权是否允许修改邮件。授权范围不是机密，缓存在这里，启动时就不用为了它去读钥匙串（会卡住界面）
    static let canModifyCache = "canModifyCache"
    static let canReadCalendarCache = "canReadCalendarCache"
    /// 上次在用的账号（邮箱）
    static let currentAccount = "currentAccount"
    /// 日历模块的显示方式：day / week / month
    static let calendarMode = "calendarMode"

    static let defaults: [String: Any] = [
        appearance: "dark",
        listDensity: "compact",
        uiDensity: "standard",
        fontSet: "jetbrains",
        fontOffset: 0.0,
        monoBody: true,
        showSnippets: true,
        groupByPR: true,
        landing: "attention",
        sidebarShown: "UNREAD,ALL",
        githubLogin: "",
        jiraName: "",
        newMailAlerts: "all",
        autoCleanRoutine: false,
        renderMarkdown: true,
        githubTextView: true,
        invertEmails: true,
        pollInterval: 10,
        openWindowAtLaunch: true,
        loadRemoteImages: true,
        markReadMode: MarkReadMode.onOpen.rawValue,
        markReadDelay: 3,
        markReadWholeThread: true,
        alertsEnabled: true,
        alertMaxAgeHours: 24,
        summaryThreshold: 5,
        defaultSound: "",
        notificationStyle: "card",
        toastSeconds: 10,
        notificationPreviewChars: 100,
        calendarReminders: true,
        calendarLeadMinutes: 0,
        strongRepeatSeconds: 10,
        strongMaxMinutes: 5,
        strongBounceDock: true,
        strongSound: "Sosumi",
        initialSyncLimit: 500,
        loadOlderBatch: 50,
        settingsTab: "general",
        canModifyCache: false,
        canReadCalendarCache: false,
        calendarMode: "day",
    ]

    /// 按账号缓存的开关。第一个账号沿用升级前的全局键，升级后第一次启动不会丢状态。
    static func cachedFlag(_ key: String, account: String) -> Bool {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: "\(key).\(account)") as? Bool { return value }
        return defaults.bool(forKey: key)
    }

    static func setCachedFlag(_ key: String, account: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "\(key).\(account)")
    }

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    private static var store: UserDefaults { .standard }

    static var pollIntervalSeconds: Int { max(3, store.integer(forKey: pollInterval)) }
    static var openWindowOnLaunch: Bool { store.bool(forKey: openWindowAtLaunch) }
    static var remoteImagesDefault: Bool { store.bool(forKey: loadRemoteImages) }
    static var autoClean: Bool { store.bool(forKey: autoCleanRoutine) }
    static var markRead: MarkReadMode { MarkReadMode(rawValue: store.string(forKey: markReadMode) ?? "") ?? .onOpen }
    static var markReadDelaySeconds: Int { max(1, store.integer(forKey: markReadDelay)) }
    static var markWholeThread: Bool { store.bool(forKey: markReadWholeThread) }
    static var alertsOn: Bool { store.bool(forKey: alertsEnabled) }
    static var newMailAlertMode: NewMailAlerts { NewMailAlerts(rawValue: store.string(forKey: newMailAlerts) ?? "all") ?? .all }
    /// 0 表示不限
    static var alertMaxAgeSeconds: TimeInterval { TimeInterval(store.integer(forKey: alertMaxAgeHours)) * 3600 }
    static var summaryThresholdCount: Int { max(1, store.integer(forKey: summaryThreshold)) }
    static var useToastCards: Bool { (store.string(forKey: notificationStyle) ?? "card") == "card" }
    /// 通知卡片显示多少秒；0 = 一直显示到点击
    static var toastDuration: TimeInterval { TimeInterval(store.integer(forKey: toastSeconds)) }
    static var notificationPreviewLimit: Int { max(0, store.integer(forKey: notificationPreviewChars)) }
    static var calendarRemindersOn: Bool { store.bool(forKey: calendarReminders) }
    static var calendarLead: TimeInterval { TimeInterval(max(0, store.integer(forKey: calendarLeadMinutes))) * 60 }
    static var defaultSoundName: String { store.string(forKey: defaultSound) ?? "" }
    static var strongRepeat: TimeInterval { TimeInterval(max(3, store.integer(forKey: strongRepeatSeconds))) }
    /// 0 表示一直响到用户处理
    static var strongMaxDuration: TimeInterval { TimeInterval(store.integer(forKey: strongMaxMinutes)) * 60 }
    static var strongBounce: Bool { store.bool(forKey: strongBounceDock) }
    static var strongSoundName: String { store.string(forKey: strongSound) ?? "Sosumi" }
    static var initialLimit: Int { max(50, store.integer(forKey: initialSyncLimit)) }
    static var olderBatch: Int { max(50, store.integer(forKey: loadOlderBatch)) }
}

extension Pref {
    static func parseShown(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { String($0) })
    }
    static func joinShown(_ set: Set<String>) -> String { set.sorted().joined(separator: ",") }
}
