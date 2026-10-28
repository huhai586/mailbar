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
}

/// 同步、提醒和状态的唯一持有者；菜单栏、主窗口和设置窗口都只读它的状态、调用它的动作。
@MainActor
final class MailService: ObservableObject {
    /// 本地邮件库有变化时 +1，界面据此刷新
    @Published private(set) var revision = 0
    @Published private(set) var paused = false
    @Published private(set) var syncing = false
    @Published private(set) var loadingOlder = false
    /// 上一次"加载更早的邮件"没拉到新邮件：说明已经到头了
    @Published private(set) var noMoreOlder = false
    @Published private(set) var loginRequired = false
    @Published private(set) var hasUnseenHits = false
    @Published private(set) var setupError: String?
    @Published private(set) var lastError: String?
    @Published private(set) var ruleWarning: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var navigation: NavigationRequest?
    /// 规则文件里的规则（侧栏据此列出所有规则，哪怕还没命中）
    @Published private(set) var rules: [Rule] = []
    /// 当前授权是否允许修改邮件状态（标记已读）。旧的只读授权需要重新授权一次。
    @Published private(set) var canModify = false

    let notifier = Notifier()
    let strongAlerts = StrongAlertCenter()
    private(set) var store: MailStore?
    /// 由主窗口的 SwiftUI 视图在出现时登记；菜单栏据此重新打开关闭了的窗口
    var openMainWindow: (() -> Void)?
    /// 由主窗口的 SwiftUI 视图登记：调用 SwiftUI 的 openSettings（比发送菜单动作可靠）
    var openSettingsWindow: (() -> Void)?
    /// 由 AppDelegate 登记：打开设置窗口并切到指定页（"general" / "alerts" / "rules" / "account"）
    var openSettings: ((String) -> Void)?

    private var oauth: OAuthClient?
    private var monitor: MailMonitor?
    private var actions: MailActions?
    private var loopTask: Task<Void, Never>?
    /// 旧邮件的 X-GitHub-Reason 是否已经补完（升级前同步的数据没有这个字段）
    private var reasonBackfillDone = false
    /// 待办 / 提醒有变化时 +1，界面据此刷新
    @Published private(set) var todoRevision = 0
    /// 每天自动简报生成好了 +1
    @Published private(set) var briefRevision = 0
    var assistantTask: Task<Void, Never>?
    var lastFollowUpCheck = Date.distantPast
    var lastBriefAttempt = Date.distantPast
    func bumpTodos() { todoRevision += 1 }
    func bumpBrief() { briefRevision += 1 }

    var accountEmail: String? { store?.accountEmail }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Lifecycle

    func start() {
        notifier.start()
        notifier.onStrongHits = { [weak self] hits in self?.strongAlerts.show(hits) }
        notifier.onFeedback = { [weak self] messageId, value in try? self?.store?.setFeedback(messageId: messageId, value: value) }
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

    private func setupCore() {
        do {
            let store = try MailStore(path: MailStore.defaultPath())
            let oauth = OAuthClient(config: try ClientConfig.load(), interactive: false)
            self.store = store
            self.oauth = oauth
            monitor = MailMonitor(oauth: oauth, store: store, initialLimit: Pref.initialLimit)
            actions = MailActions(oauth: oauth, store: store)
            canModify = UserDefaults.standard.bool(forKey: Pref.canModifyCache)
            #if DEBUG
            // 排查用：在邮件库副本上只改本地、不碰 Gmail（配合 MAIL_DB 指向副本）
            if ProcessInfo.processInfo.environment["MAIL_FAKE_REMOTE"] != nil {
                actions = MailActions(localOnlyStore: store)
                canModify = true
            }
            #endif
            setupError = nil
        } catch {
            setupError = error.localizedDescription
            log.error("setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync loop

    func tick() async {
        if monitor == nil {
            setupCore()
            if store != nil { revision += 1 }
        }
        guard let monitor, !paused, !syncing else { return }
        #if DEBUG
        // 调试用：`--args -noSync YES` 只用本地数据，不同步（也就不会触发钥匙串授权弹窗），方便检查界面
        if UserDefaults.standard.bool(forKey: "noSync") { return }
        #endif
        syncing = true
        defer { syncing = false }
        monitor.alertMaxAge = Pref.alertMaxAgeSeconds > 0 ? Pref.alertMaxAgeSeconds : .infinity
        do {
            monitor.newMailAlerts = Pref.newMailAlertMode
            monitor.aiJudge = Self.configuredJudge()
            let result = try await monitor.syncOnce()
            lastSync = Date()
            lastError = nil
            loginRequired = false
            ruleWarning = result.ruleWarning
            updateCanModify()
            if result.rulesChanged { reloadRules() }
            if result.hasChanges || result.rulesChanged { revision += 1 }
            if !result.alerts.isEmpty {
                hasUnseenHits = true
                if Pref.alertsOn { notifier.deliver(result.alerts, account: accountEmail) }
            }
            // 设置里开了"自动清理"：把新到的例行机器人邮件直接标为已读（需要修改权限）
            if Pref.autoClean, canModify, result.hasChanges, let store,
               let ids = try? store.unreadMessageIDs(kind: .botRoutine), !ids.isEmpty {
                await setRead(true, messageIds: ids)
            }
            // 没有新邮件的空闲轮次里，悄悄给旧邮件补 GitHub 原因（每次很少，不占配额）
            if !reasonBackfillDone, !result.hasChanges {
                let done = (try? await monitor.backfillReasons(limit: 8)) ?? 0
                if done == 0 { reasonBackfillDone = true } else { revision += 1 }
            }
        } catch MailError.loginRequired {
            if !loginRequired {
                notifier.post(id: "login-required", title: "Gmail 需要重新登录", body: "点击菜单栏图标 → 登录 Google…", threadId: nil, useDefaultSound: true)
            }
            loginRequired = true
            lastError = MailError.loginRequired.localizedDescription
        } catch {
            lastError = error.localizedDescription
            log.error("sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    func syncNow() { Task { await tick() } }

    /// 用户主动刷新（按钮、r、菜单）。
    /// 设置里打开了「AI 判断通知」并选好服务时，返回对应的判定器。
    static func configuredJudge() -> AINotifyJudge? {
        let config = AIConfigStore.read()
        guard config.notifyEnabled, let provider = config.active else { return nil }
        return AINotifyJudge(chat: AIClient(provider: provider, apiKey: AIKeyStore.key(for: provider.id)), prompt: config.notifyPrompt)
    }

    func manualSync() { syncNow() }

    /// 切回应用时：距离上次同步超过几秒就立刻同步一次，保证一眼看到的是最新的。
    func syncIfStale(after seconds: TimeInterval = 3) {
        if Date().timeIntervalSince(lastSync ?? .distantPast) > seconds { syncNow() }
    }

    func togglePause() {
        paused.toggle()
        if !paused { syncNow() }
    }

    /// 浏览器授权。常驻程序里的授权请求的是"可修改邮件"范围，所以旧的只读授权也靠它升级。
    func signIn() {
        guard let oauth else { return }
        Task {
            do {
                try await oauth.signIn()
                loginRequired = false
                lastError = nil
                updateCanModify()
                await tick()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// 同步成功之后令牌已经在内存里，读授权范围不会再碰钥匙串。
    private func updateCanModify() {
        let value = oauth?.canModify ?? false
        canModify = value
        UserDefaults.standard.set(value, forKey: Pref.canModifyCache)
    }

    func signOut() {
        oauth?.signOut()
        canModify = false
        UserDefaults.standard.set(false, forKey: Pref.canModifyCache)
        loginRequired = true
        lastError = MailError.loginRequired.localizedDescription
    }

    /// 标记已读 / 未读：本地立刻变化，随后同步到 Gmail；失败会回滚并在状态栏显示原因。
    func setRead(_ read: Bool, messageIds: [String]) async {
        guard let actions, !messageIds.isEmpty else {
            trace("[setRead] 跳过：actions=%d ids=%d", actions != nil, messageIds.count)
            return
        }
        trace("[setRead] read=%d ids=%d", read, messageIds.count)
        #if DEBUG
        // 调试的"不同步"模式不能碰邮箱：不改本地、也不向 Gmail 发任何请求
        if UserDefaults.standard.bool(forKey: "noSync"), ProcessInfo.processInfo.environment["MAIL_FAKE_REMOTE"] == nil { return }
        #endif
        do {
            try await actions.setRead(read, messageIds: messageIds, onLocalChange: { [weak self] in
                Task { @MainActor in self?.revision += 1 }
            })
            lastError = nil
            trace("[setRead] 完成")
        } catch MailError.reauthorizationRequired {
            canModify = false
            UserDefaults.standard.set(false, forKey: Pref.canModifyCache)
            revision += 1   // 回滚后的状态
            lastError = MailError.reauthorizationRequired.localizedDescription
        } catch {
            revision += 1
            trace("[setRead] 失败：%@", error.localizedDescription)
            lastError = "标记失败：\(error.localizedDescription)"
        }
    }

    /// 再往前拉 count 封历史邮件。
    func loadOlder(count: Int) async {
        guard let monitor, let store, !loadingOlder else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noSync") { return }
        #endif
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let before = (try? store.messageCount()) ?? 0
            _ = try await monitor.loadOlder(limit: before + count)
            // 一封都没多出来 = 邮箱里已经没有更早的了；列表滚到底的自动加载据此停下，不会反复请求
            noMoreOlder = ((try? store.messageCount()) ?? 0) <= before
            revision += 1
            lastError = nil
        } catch {
            lastError = "加载更早的邮件失败：\(error.localizedDescription)"
        }
    }

    /// 清掉同步位置，按"首次同步邮件数"设置重新完整同步。
    func resyncAll() async {
        guard let oauth, let store, !syncing else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noSync") { return }
        #endif
        monitor = MailMonitor(oauth: oauth, store: store, initialLimit: Pref.initialLimit)
        reasonBackfillDone = false
        syncing = true
        defer { syncing = false }
        noMoreOlder = false
        do {
            _ = try await monitor?.syncOnce(forceFull: true)
            lastSync = Date()
            lastError = nil
            revision += 1
        } catch {
            lastError = "重新同步失败：\(error.localizedDescription)"
        }
    }

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
        return (true, "已导入。已有的授权属于旧客户端，重新启动 MailBar 并重新授权后生效。")
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
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let changed = (try? store.reclassifyKinds(config: config)) ?? 0
            self.kindStatus = changed == 0 ? "已保存，没有邮件的类型发生变化" : "已保存，\(changed) 封邮件重新分类"
            if changed > 0 {
                try? self.monitor?.rematch()   // 规则命中依赖邮件类型（机器人邮件里的"提及"不算）
                self.revision += 1
            }
        }
    }

    /// 手动按当前规则对本地所有邮件重新分类。
    func reclassifyNow() {
        guard let store else { return }
        let changed = (try? store.reclassifyKinds(config: kindConfig)) ?? 0
        kindStatus = changed == 0 ? "没有邮件的类型发生变化" : "\(changed) 封邮件重新分类"
        if changed > 0 {
            try? monitor?.rematch()
            revision += 1
        }
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
            lastError = "添加推荐规则失败：\(error.localizedDescription)"
        }
    }

    func markHitsSeen() { hasUnseenHits = false }

    func requestNavigation(mailbox: Mailbox?, threadId: String?) {
        navigation = NavigationRequest(mailbox: mailbox, threadId: threadId)
    }

    func consumeNavigation(_ request: NavigationRequest) {
        if navigation == request { navigation = nil }
    }

    // MARK: - Status text

    var statusLine: String {
        if let setupError { return "⚠️ " + (setupError.split(separator: "\n").first.map(String.init) ?? setupError) }
        if paused { return "已暂停" }
        if syncing { return "同步中…" }
        if loadingOlder { return "正在加载更早的邮件…" }
        if let lastError { return "⚠️ \(lastError)" }
        let count = (try? store?.messageCount()) ?? 0
        guard let lastSync else { return "尚未同步" }
        return "上次同步 \(timeFormatter.string(from: lastSync)) · 本地 \(count) 封"
    }
}
