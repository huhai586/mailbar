import AppKit
import Combine
import MailCore
import os

private let log = Logger(subsystem: "com.huhai.mailbar", category: "service")

/// 界面要求跳转到某个邮箱 / 某个会话（点通知、点菜单里的命中邮件时发出）。
struct NavigationRequest: Equatable {
    let id = UUID()
    var mailbox: Mailbox?
    var threadId: String?
    /// 会话属于哪个账号；nil = 当前账号
    var accountID: String?
}

/// 应用的两个并列模块：邮件和日历。
enum AppModule: String { case mail, calendar }

/// 一个账号运行时的全部东西：邮件库、授权、同步器，以及它自己的同步状态。
/// 状态变化时通知 MailService，界面据此刷新。
@MainActor
final class AccountSession {
    let account: Account
    let store: MailStore
    let oauth: OAuthClient
    var monitor: MailMonitor
    var actions: MailActions
    let calendarSync: CalendarSync
    var onChange: (() -> Void)?

    var syncing = false { didSet { onChange?() } }
    var loadingOlder = false { didSet { onChange?() } }
    /// 上一次"加载更早的邮件"没拉到新邮件：说明已经到头了
    var noMoreOlder = false { didSet { onChange?() } }
    var loginRequired = false { didSet { onChange?() } }
    var lastError: String? { didSet { onChange?() } }
    var lastSync: Date? { didSet { onChange?() } }
    /// 当前授权是否允许修改邮件状态（标记已读）。旧的只读授权需要重新授权一次。
    var canModify = false { didSet { onChange?() } }
    /// 当前授权是否包含日历（旧版本授权的没有，要重新授权一次）
    var canReadCalendar = false { didSet { onChange?() } }
    var calendarSyncing = false { didSet { onChange?() } }
    var calendarError: String? { didSet { onChange?() } }
    /// 旧邮件的 X-GitHub-Reason 是否已经补完（升级前同步的数据没有这个字段）
    var reasonBackfillDone = false

    var id: String { account.id }

    init(account: Account, store: MailStore, oauth: OAuthClient, initialLimit: Int) {
        self.account = account
        self.store = store
        self.oauth = oauth
        monitor = MailMonitor(oauth: oauth, store: store, initialLimit: initialLimit)
        actions = MailActions(oauth: oauth, store: store)
        calendarSync = CalendarSync(oauth: oauth, store: store)
    }
}

/// 日历里的一个日程，带上它属于哪个账号（界面据此显示账号颜色和名字）。
struct AccountEvent: Identifiable, Equatable {
    let event: CalendarEvent
    let accountID: String
    let accountEmail: String
    let colorIndex: Int
    var id: String { accountID + "/" + event.id }
}

/// 同步、提醒和状态的唯一持有者；菜单栏、主窗口和设置窗口都只读它的状态、调用它的动作。
/// 支持多个 Gmail 账号：每个账号一个 AccountSession，同步循环依次同步所有账号；界面一次显示「当前账号」的邮件，
/// 日历模块则把所有账号的日程合在一起。
@MainActor
final class MailService: ObservableObject {
    /// 本地邮件库有变化时 +1，界面据此刷新
    @Published private(set) var revision = 0
    @Published private(set) var paused = false
    @Published private(set) var hasUnseenHits = false
    @Published private(set) var setupError: String?
    @Published private(set) var ruleWarning: String?
    @Published private(set) var navigation: NavigationRequest?
    /// 规则文件里的规则（侧栏据此列出所有规则，哪怕还没命中）
    @Published private(set) var rules: [Rule] = []
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var currentAccountID: String?
    /// 各账号收件箱的未读会话数（账号切换器里显示）
    @Published private(set) var accountUnread: [String: Int] = [:]
    @Published var module: AppModule = .mail
    /// 日历数据有变化时 +1
    @Published private(set) var calendarRevision = 0
    /// 添加账号的浏览器授权正在进行
    @Published private(set) var addingAccount = false
    @Published private(set) var accountMessage: String?

    let notifier = Notifier()
    let toasts = ToastCenter()
    let strongAlerts = StrongAlertCenter()
    /// 由主窗口的 SwiftUI 视图在出现时登记；菜单栏据此重新打开关闭了的窗口
    var openMainWindow: (() -> Void)?
    /// 由主窗口的 SwiftUI 视图登记：调用 SwiftUI 的 openSettings（比发送菜单动作可靠）
    var openSettingsWindow: (() -> Void)?
    /// 由 AppDelegate 登记：打开设置窗口并切到指定页（"general" / "alerts" / "rules" / "account"）
    var openSettings: ((String) -> Void)?

    private var clientConfig: ClientConfig?
    private(set) var sessions: [String: AccountSession] = [:]
    private var loopTask: Task<Void, Never>?
    /// 邮件 id → 它属于哪个账号（强提醒卡片点「查看」时要跳到对应账号）
    private var hitAccounts: [String: String] = [:]
    /// 待办 / 提醒有变化时 +1，界面据此刷新
    @Published private(set) var todoRevision = 0
    /// 每天自动简报生成好了 +1
    @Published private(set) var briefRevision = 0
    var assistantTask: Task<Void, Never>?
    var lastFollowUpCheck = Date.distantPast
    var lastBriefAttempt = Date.distantPast
    func bumpTodos() { todoRevision += 1 }
    func bumpBrief() { briefRevision += 1 }

    // MARK: 当前账号

    /// 当前账号的会话
    var session: AccountSession? { currentAccountID.flatMap { sessions[$0] } }
    /// 所有账号的会话（按添加顺序）
    var allSessions: [AccountSession] { accounts.compactMap { sessions[$0.id] } }
    var store: MailStore? { session?.store }
    var accountEmail: String? { session?.account.email }
    var syncing: Bool { allSessions.contains { $0.syncing } }
    var loadingOlder: Bool { session?.loadingOlder ?? false }
    var noMoreOlder: Bool { session?.noMoreOlder ?? false }
    /// 当前账号需要（重新）登录；还没有任何账号时也算，界面据此引导添加
    var loginRequired: Bool { session?.loginRequired ?? false }
    var canModify: Bool { session?.canModify ?? false }
    var lastError: String? { session?.lastError ?? allSessions.compactMap(\.lastError).first }
    var lastSync: Date? { session?.lastSync }
    var hasAccounts: Bool { !accounts.isEmpty }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Lifecycle

    func start() {
        notifier.toasts = toasts
        toasts.onFeedback = { [weak self] item, value in
            guard let messageId = item.judgedMessageId else { return }
            let target = item.accountID.flatMap { self?.sessions[$0] } ?? self?.session
            try? target?.store.setFeedback(messageId: messageId, value: value)
        }
        notifier.start()
        notifier.onStrongHits = { [weak self] hits in self?.strongAlerts.show(hits) }
        notifier.onFeedback = { [weak self] account, messageId, value in
            let target = account.flatMap { self?.sessions[$0] } ?? self?.session
            try? target?.store.setFeedback(messageId: messageId, value: value)
        }
        loadKindConfig()
        setupCore()
        reloadRules()
        revision += 1   // 让界面立刻显示已有的本地邮件
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(Pref.pollIntervalSeconds) * 1_000_000_000)
            }
        }
        startAssistantLoop()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // 刚唤醒时网络可能还没恢复，稍等再同步
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.tick()
            }
        }
    }

    /// 读 OAuth 客户端文件和账号清单，给每个账号开一个会话。
    private func setupCore() {
        do {
            clientConfig = try ClientConfig.load()
            setupError = nil
        } catch {
            setupError = error.localizedDescription
            log.error("setup failed: \(error.localizedDescription)")
            return
        }
        let registry = AccountRegistry.load()
        accounts = registry.accounts
        for account in registry.accounts where sessions[account.id] == nil { openSession(account) }
        let saved = UserDefaults.standard.string(forKey: Pref.currentAccount)
        currentAccountID = registry.account(id: saved ?? "")?.id ?? registry.accounts.first?.id
        refreshAccountUnread()
    }

    @discardableResult
    private func openSession(_ account: Account) -> AccountSession? {
        guard let clientConfig else { return nil }
        do {
            let store = try MailStore(path: account.dbPath)
            let oauth = OAuthClient(config: clientConfig, interactive: false, tokenKey: account.tokenKey)
            let session = AccountSession(account: account, store: store, oauth: oauth, initialLimit: Pref.initialLimit)
            session.onChange = { [weak self] in self?.objectWillChange.send() }
            // 授权范围不是机密，缓存起来，启动时不用为了它去读钥匙串（会卡住界面）
            session.canModify = Pref.cachedFlag(Pref.canModifyCache, account: account.id)
            session.canReadCalendar = Pref.cachedFlag(Pref.canReadCalendarCache, account: account.id)
            #if DEBUG
            // 排查用：在邮件库副本上只改本地、不碰 Gmail（配合 MAIL_DB 指向副本）
            if ProcessInfo.processInfo.environment["MAIL_FAKE_REMOTE"] != nil {
                session.actions = MailActions(localOnlyStore: store)
                session.canModify = true
            }
            #endif
            sessions[account.id] = session
            return session
        } catch {
            setupError = "打开 \(account.email) 的邮件库失败：\(error.localizedDescription)"
            log.error("open session failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Sync loop

    func tick() async {
        if clientConfig == nil {
            setupCore()
            if store != nil { revision += 1 }
        }
        guard !paused, !syncing else { return }
        #if DEBUG
        // 调试用：`--args -noSync YES` 只用本地数据，不同步（也就不会触发钥匙串授权弹窗），方便检查界面
        if UserDefaults.standard.bool(forKey: "noSync") { return }
        #endif
        for session in allSessions { await sync(session) }
        await syncCalendars(force: false)
    }

    private func sync(_ session: AccountSession) async {
        session.syncing = true
        defer { session.syncing = false }
        let monitor = session.monitor
        monitor.alertMaxAge = Pref.alertMaxAgeSeconds > 0 ? Pref.alertMaxAgeSeconds : .infinity
        do {
            monitor.newMailAlerts = Pref.newMailAlertMode
            monitor.aiJudge = Self.configuredJudge()
            // 先把上次没发出去的已读 / 未读补发给 Gmail（失败了下轮再试，本地状态不受影响）
            if session.canModify { try? await session.actions.flushPending() }
            let result = try await monitor.syncOnce()
            session.lastSync = Date()
            session.lastError = nil
            session.loginRequired = false
            if session.id == currentAccountID { ruleWarning = result.ruleWarning }
            updateCanModify(session)
            if result.rulesChanged { reloadRules() }
            if result.hasChanges || result.rulesChanged { bump() }
            if !result.alerts.isEmpty {
                hasUnseenHits = true
                for hit in result.alerts { hitAccounts[hit.messageId] = session.id }
                if Pref.alertsOn { notifier.deliver(result.alerts, account: session.account.email, accountID: session.id) }
            }
            // 设置里开了"自动清理"：把新到的例行机器人邮件直接标为已读（需要修改权限）
            if Pref.autoClean, session.canModify, result.hasChanges,
               let ids = try? session.store.unreadMessageIDs(kind: .botRoutine), !ids.isEmpty {
                await setRead(true, messageIds: ids, in: session)
            }
            // 没有新邮件的空闲轮次里，悄悄给旧邮件补 GitHub 原因（每次很少，不占配额）
            if !session.reasonBackfillDone, !result.hasChanges {
                let done = (try? await monitor.backfillReasons(limit: 8)) ?? 0
                if done == 0 { session.reasonBackfillDone = true } else { bump() }
            }
        } catch MailError.loginRequired {
            if !session.loginRequired {
                notifier.post(id: "login-required-\(session.id)", title: "\(session.account.email) 需要重新登录",
                              body: "点击菜单栏图标 → 登录 Google…", threadId: nil, useDefaultSound: true)
            }
            session.loginRequired = true
            session.lastError = MailError.loginRequired.localizedDescription
        } catch {
            session.lastError = error.localizedDescription
            log.error("sync failed (\(session.account.email)): \(error.localizedDescription)")
        }
    }

    /// 本地邮件库有变化：界面刷新，账号切换器里的未读数重算。
    private func bump() {
        revision += 1
        refreshAccountUnread()
    }

    private func refreshAccountUnread() {
        var counts: [String: Int] = [:]
        for session in allSessions { counts[session.id] = (try? session.store.unreadThreadCount(in: .label("INBOX"))) ?? 0 }
        if counts != accountUnread { accountUnread = counts }
    }

    // MARK: - Actions

    func syncNow() { Task { await tick() } }

    /// 设置里打开了「AI 判断通知」并选好服务时，返回对应的判定器。
    static func configuredJudge() -> AINotifyJudge? {
        let config = AIConfigStore.read()
        guard config.notifyEnabled, let provider = config.active else { return nil }
        return AINotifyJudge(chat: AIClient(provider: provider, apiKey: AIKeyStore.key(for: provider.id)), prompt: config.notifyPrompt)
    }

    /// 用户主动刷新（按钮、r、菜单）。
    func manualSync() {
        syncNow()
        Task { await syncCalendars(force: true) }
    }

    /// 切回应用时：距离上次同步超过几秒就立刻同步一次，保证一眼看到的是最新的。
    func syncIfStale(after seconds: TimeInterval = 3) {
        if Date().timeIntervalSince(lastSync ?? .distantPast) > seconds { syncNow() }
    }

    func togglePause() {
        paused.toggle()
        if !paused { syncNow() }
    }

    /// 浏览器授权。没有任何账号时是「添加账号」；否则是给当前账号重新授权（旧的只读授权、缺日历权限、令牌失效都靠它）。
    func signIn() {
        guard let session else { addAccount(); return }
        reauthorize(session)
    }

    func reauthorize(_ session: AccountSession) {
        Task {
            do {
                try await session.oauth.reauthorize(expectedEmail: session.account.email)
                session.loginRequired = false
                session.lastError = nil
                updateCanModify(session)
                session.canReadCalendar = session.oauth.canReadCalendar
                Pref.setCachedFlag(Pref.canReadCalendarCache, account: session.id, session.canReadCalendar)
                await sync(session)
                await syncCalendars(force: true)
            } catch {
                session.lastError = error.localizedDescription
            }
        }
    }

    /// 同步成功之后令牌已经在内存里，读授权范围不会再碰钥匙串。
    private func updateCanModify(_ session: AccountSession) {
        session.canModify = session.oauth.canModify
        session.canReadCalendar = session.oauth.canReadCalendar
        Pref.setCachedFlag(Pref.canModifyCache, account: session.id, session.canModify)
        Pref.setCachedFlag(Pref.canReadCalendarCache, account: session.id, session.canReadCalendar)
    }

    /// 退出登录：只删这个账号的令牌，邮件库和账号还在，随时可以重新授权。
    func signOut() {
        guard let session else { return }
        session.oauth.signOut()
        session.canModify = false
        session.canReadCalendar = false
        Pref.setCachedFlag(Pref.canModifyCache, account: session.id, false)
        Pref.setCachedFlag(Pref.canReadCalendarCache, account: session.id, false)
        session.loginRequired = true
        session.lastError = MailError.loginRequired.localizedDescription
    }

    // MARK: - 账号管理

    func switchAccount(to id: String) {
        guard sessions[id] != nil, id != currentAccountID else { return }
        currentAccountID = id
        UserDefaults.standard.set(id, forKey: Pref.currentAccount)
        module = .mail
        ruleWarning = nil
        revision += 1
    }

    /// 添加一个 Gmail 账号：弹出浏览器让用户选账号并授权，成功后立刻开始同步并切换过去。
    func addAccount() {
        guard !addingAccount else { return }
        guard let clientConfig else {
            accountMessage = setupError ?? "还没有导入 OAuth 客户端文件。"
            return
        }
        addingAccount = true
        accountMessage = nil
        Task {
            defer { addingAccount = false }
            do {
                let (email, key) = try await OAuthClient.addAccount(config: clientConfig)
                var registry = AccountRegistry.load()
                guard let account = registry.add(email: email, tokenKey: key, directory: AccountRegistry.defaultDirectory()) else {
                    OAuthClient(config: clientConfig, tokenKey: key).signOut()   // 已经有了：丢掉这次多余的令牌
                    accountMessage = "\(email) 已经添加过了。要重新授权，请在它的行里点「重新授权」。"
                    if sessions[email] != nil { switchAccount(to: email) }
                    return
                }
                try registry.write()
                accounts = registry.accounts
                if openSession(account) != nil {
                    currentAccountID = account.id
                    UserDefaults.standard.set(account.id, forKey: Pref.currentAccount)
                    module = .mail
                    accountMessage = "已添加 \(email)，正在同步。"
                    revision += 1
                    syncNow()
                }
            } catch {
                accountMessage = "添加账号失败：\(error.localizedDescription)"
            }
        }
    }

    /// 移除账号：删掉它的令牌和账号记录；deleteData 为 true 时一并删掉本地邮件库。
    func removeAccount(id: String, deleteData: Bool) {
        guard let session = sessions[id] else { return }
        session.oauth.signOut()
        sessions[id] = nil
        var registry = AccountRegistry.load()
        registry.remove(id: id)
        try? registry.write()
        accounts = registry.accounts
        if deleteData {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: session.account.dbPath + suffix) }
        }
        if currentAccountID == id {
            currentAccountID = accounts.first?.id
            UserDefaults.standard.set(currentAccountID, forKey: Pref.currentAccount)
        }
        accountUnread[id] = nil
        calendarRevision += 1
        revision += 1
    }

    func clearAccountMessage() { accountMessage = nil }

    /// 强提醒卡片点「查看」：这封邮件属于哪个账号。
    func accountID(forMessage id: String) -> String? { hitAccounts[id] }

    /// 标记已读 / 未读：本地立刻变化，随后同步到 Gmail；失败会回滚并在状态栏显示原因。
    /// session 默认是当前账号（界面里看的就是它的邮件）。
    func setRead(_ read: Bool, messageIds: [String], in target: AccountSession? = nil) async {
        guard let session = target ?? session, !messageIds.isEmpty else {
            trace("[setRead] 跳过：session=%d ids=%d", (target ?? session) != nil, messageIds.count)
            return
        }
        trace("[setRead] read=%d ids=%d", read, messageIds.count)
        #if DEBUG
        // 调试的"不同步"模式不能碰邮箱：不改本地、也不向 Gmail 发任何请求
        if UserDefaults.standard.bool(forKey: "noSync"), ProcessInfo.processInfo.environment["MAIL_FAKE_REMOTE"] == nil { return }
        #endif
        do {
            try await session.actions.setRead(read, messageIds: messageIds, onLocalChange: { [weak self] in
                Task { @MainActor in self?.bump() }
            })
            session.lastError = nil
            trace("[setRead] 完成")
        } catch MailError.reauthorizationRequired {
            session.canModify = false
            Pref.setCachedFlag(Pref.canModifyCache, account: session.id, false)
            bump()   // 回滚后的状态
            session.lastError = MailError.reauthorizationRequired.localizedDescription
        } catch {
            bump()
            trace("[setRead] 失败：%@", error.localizedDescription)
            session.lastError = "标记失败：\(error.localizedDescription)"
        }
    }

    /// 再往前拉 count 封历史邮件。
    func loadOlder(count: Int) async {
        guard let session, !session.loadingOlder else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noSync") { return }
        #endif
        session.loadingOlder = true
        defer { session.loadingOlder = false }
        do {
            let before = (try? session.store.messageCount()) ?? 0
            _ = try await session.monitor.loadOlder(limit: before + count)
            // 一封都没多出来 = 邮箱里已经没有更早的了；列表滚到底的自动加载据此停下，不会反复请求
            session.noMoreOlder = ((try? session.store.messageCount()) ?? 0) <= before
            bump()
            session.lastError = nil
        } catch {
            session.lastError = "加载更早的邮件失败：\(error.localizedDescription)"
        }
    }

    /// 清掉同步位置，按"首次同步邮件数"设置重新完整同步。
    func resyncAll() async {
        guard let session, !session.syncing else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noSync") { return }
        #endif
        session.monitor = MailMonitor(oauth: session.oauth, store: session.store, initialLimit: Pref.initialLimit)
        session.reasonBackfillDone = false
        session.syncing = true
        defer { session.syncing = false }
        session.noMoreOlder = false
        do {
            _ = try await session.monitor.syncOnce(forceFull: true)
            session.lastSync = Date()
            session.lastError = nil
            bump()
        } catch {
            session.lastError = "重新同步失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 日历

    /// 每个账号的日历多久同步一次
    private static let calendarStaleAfter: TimeInterval = 10 * 60

    /// 同步所有账号的日历。force = false 时只同步超过 10 分钟没同步的。
    func syncCalendars(force: Bool) async {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noSync") { return }
        #endif
        for session in allSessions where session.canReadCalendar && !session.loginRequired && !session.calendarSyncing {
            let last = session.store.lastCalendarSync ?? .distantPast
            guard force || Date().timeIntervalSince(last) > Self.calendarStaleAfter else { continue }
            session.calendarSyncing = true
            defer { session.calendarSyncing = false }
            do {
                try await session.calendarSync.sync()
                session.calendarError = nil
            } catch MailError.reauthorizationRequired {
                session.canReadCalendar = false
                Pref.setCachedFlag(Pref.canReadCalendarCache, account: session.id, false)
                session.calendarError = "需要重新授权才能读取日历"
            } catch {
                session.calendarError = error.localizedDescription
            }
            calendarRevision += 1
        }
    }

    /// 日程提醒：开始前 N 分钟（设置里选，默认开始时）弹一条通知，每个日程只提醒一次。每分钟检查一次。
    private var remindedEvents = Set<String>()

    func checkCalendarReminders(now: Date = Date()) {
        guard Pref.alertsOn, Pref.calendarRemindersOn else { return }
        let lead = Pref.calendarLead
        // 提醒时刻落在 [now - 150 秒, now] 里就提醒：错过一两次检查也能补上，应用晚启动超过两分半钟的就不补了
        let window: TimeInterval = 150
        let upcoming = calendarEvents(from: now.addingTimeInterval(-window), to: now.addingTimeInterval(lead + 60))
        trace("[CalReminder] upcoming=%d lead=%.0f", upcoming.count, lead)
        trace("[CalReminder] upcoming=%d lead=%.0f", upcoming.count, lead)
        let dueIDs = Set(CalendarReminders.due(upcoming.map(\.event), now: now, lead: lead, window: window).map(\.id))
        for item in upcoming where dueIDs.contains(item.event.id) {
            let e = item.event
            guard remindedEvents.insert("\(item.id)|\(e.start.timeIntervalSince1970)").inserted else { continue }
            trace("[CalReminder] 提醒 %@", e.title)
            trace("[CalReminder] 提醒 %@", e.title)
            let when = lead <= 0 ? "现在开始" : "\(Int(lead / 60)) 分钟后开始"
            var body = CalendarFormat.timeRange(e)
            if !e.location.isEmpty { body += " · " + e.location }
            notifier.post(id: "cal-\(item.id)", title: "\(when)：\(e.title)", body: body, threadId: nil, useDefaultSound: true,
                          accountID: item.accountID, calendar: true, joinURL: e.meetingURL.flatMap(URL.init(string:)))
        }
        if remindedEvents.count > 500 { remindedEvents.removeAll() }
    }

    /// 所有账号在 [from, to) 内的日程，按开始时间排序。
    func calendarEvents(from: Date, to: Date) -> [AccountEvent] {
        var result: [AccountEvent] = []
        for session in allSessions {
            let events = (try? session.store.calendarEvents(from: from, to: to)) ?? []
            result += events.map { AccountEvent(event: $0, accountID: session.id, accountEmail: session.account.email, colorIndex: session.account.colorIndex) }
        }
        // 同一个会议邀请发给了好几个自己的邮箱时，每个账号的日历里都有一份：合并成一条（留最先添加的账号那份）
        var seen = Set<String>()
        result = result.filter { seen.insert("\($0.event.title)|\($0.event.start.timeIntervalSince1970)|\($0.event.end.timeIntervalSince1970)|\($0.event.isAllDay)").inserted }
        return result.sorted {
            if $0.event.start != $1.event.start { return $0.event.start < $1.event.start }
            return $0.event.isAllDay && !$1.event.isAllDay
        }
    }

    var calendarSyncing: Bool { allSessions.contains { $0.calendarSyncing } }
    /// 还没授权日历的账号（界面提示用户重新授权）
    var accountsNeedingCalendarAuth: [AccountSession] { allSessions.filter { !$0.canReadCalendar } }
    var calendarErrors: [String] { allSessions.compactMap { s in s.calendarError.map { "\(s.account.email)：\($0)" } } }

    // MARK: - OAuth 客户端

    /// 导入 GCP 下载的客户端 JSON。返回给用户看的结果说明。
    func importClientJSON(from url: URL) -> (ok: Bool, message: String) {
        let hadSetupError = setupError != nil
        do {
            try ClientConfig.install(from: url)
        } catch {
            return (false, error.localizedDescription)
        }
        if hadSetupError {
            setupCore()
            revision += 1
            syncNow()
            return (true, "已导入。正在连接，如果还没有登录，下面点「授权」。")
        }
        return (true, "已导入。已有的授权属于旧客户端，重新启动 Sift 并重新授权后生效。")
    }

    // MARK: - 识别规则（真人 / 机器人 / 推送）

    @Published private(set) var kindConfig = KindConfig.defaults
    @Published private(set) var kindStatus: String?
    private var reclassifyTask: Task<Void, Never>?

    func loadKindConfig() {
        KindConfigStore.shared.load()
        kindConfig = KindConfigStore.shared.config
    }

    /// 设置里改了识别规则：立刻生效、存盘，稍等一下（连续编辑合并）后对所有本地邮件重新分类。
    func updateKindConfig(_ config: KindConfig) {
        guard config != kindConfig else { return }
        kindConfig = config
        KindConfigStore.shared.config = config
        do { try KindConfigStore.write(config) } catch { kindStatus = "保存失败：\(error.localizedDescription)"; return }
        reclassifyTask?.cancel()
        reclassifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            let changed = self.reclassifyAll(config: config)
            self.kindStatus = changed == 0 ? "已保存，没有邮件的类型发生变化" : "已保存，\(changed) 封邮件重新分类"
            if changed > 0 { self.revision += 1 }
        }
    }

    /// 手动按当前规则对本地所有邮件重新分类。
    func reclassifyNow() {
        let changed = reclassifyAll(config: kindConfig)
        kindStatus = changed == 0 ? "没有邮件的类型发生变化" : "\(changed) 封邮件重新分类"
        if changed > 0 { revision += 1 }
    }

    /// 识别规则是所有账号共用的：对每个账号的本地邮件都重新分类。
    private func reclassifyAll(config: KindConfig) -> Int {
        var total = 0
        for session in allSessions {
            let changed = (try? session.store.reclassifyKinds(config: config)) ?? 0
            if changed > 0 { try? session.monitor.rematch() }   // 规则命中依赖邮件类型（机器人邮件里的"提及"不算）
            total += changed
        }
        return total
    }

    /// 邮件卡片上的"归类为…"：给这个发件人加一条覆盖规则（放在最前面，优先级最高）。
    func setKind(forSender address: String, _ kind: MessageKind) {
        var config = kindConfig
        config.overrides.removeAll { $0.field == .sender && $0.pattern.caseInsensitiveCompare(address) == .orderedSame }
        config.overrides.insert(.init(field: .sender, pattern: address, kind: kind), at: 0)
        updateKindConfig(config)
    }

    // MARK: - Rules

    func reloadRules() {
        if let loaded = try? RuleStore.read() { rules = loaded }
    }

    /// 设置界面保存了规则文件：重新读取并立刻同步一次，让新规则马上生效。
    func rulesFileChanged() {
        reloadRules()
        syncNow()
    }

    /// 一键添加推荐规则（GitHub / Jira / Google 文档，只补缺的，不动已有规则）。
    func addRecommendedRules() {
        do {
            let existing = try RuleStore.read()
            try RuleStore.write(existing + RuleTemplates.missing(from: RuleTemplates.github + RuleTemplates.jira, in: existing))
            rulesFileChanged()
        } catch {
            ruleWarning = "添加推荐规则失败：\(error.localizedDescription)"
        }
    }

    func markHitsSeen() { hasUnseenHits = false }

    func requestNavigation(mailbox: Mailbox?, threadId: String?, accountID: String? = nil) {
        if let accountID, sessions[accountID] != nil { switchAccount(to: accountID) }
        module = .mail
        navigation = NavigationRequest(mailbox: mailbox, threadId: threadId, accountID: accountID)
    }

    func consumeNavigation(_ request: NavigationRequest) {
        if navigation == request { navigation = nil }
    }

    // MARK: - Status text

    var statusLine: String {
        if let setupError { return "⚠️ " + (setupError.split(separator: "\n").first.map(String.init) ?? setupError) }
        if accounts.isEmpty { return "还没有账号，点「添加 Gmail 账号」开始" }
        if paused { return "已暂停" }
        if syncing { return "同步中…" }
        if loadingOlder { return "正在加载更早的邮件…" }
        if let lastError { return "⚠️ \(lastError)" }
        if let other = allSessions.first(where: { $0.id != currentAccountID && $0.lastError != nil }), let error = other.lastError {
            return "⚠️ \(other.account.email)：\(error)"
        }
        let count = (try? store?.messageCount()) ?? 0
        guard let lastSync else { return "尚未同步" }
        return "上次同步 \(timeFormatter.string(from: lastSync)) · 本地 \(count) 封"
    }
}
