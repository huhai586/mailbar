import Combine
import MailCore
import SwiftUI

/// 阅读界面的状态：当前邮箱、搜索词、列表、选中的会话和邮件。数据都来自 MailStore 的本地查询。
/// 详情页的筛选：先分"真人 / 自动化"，自动化里再分"失败 / 例行"。
struct DetailFilter: Equatable {
    enum Tab: String { case all, human, auto }
    enum Sub: String { case all, alert, push, routine }
    var tab: Tab = .all
    var sub: Sub = .all

    func includes(_ kind: MessageKind) -> Bool {
        switch tab {
        case .all: return true
        case .human: return kind == .human
        case .auto:
            guard kind != .human else { return false }
            switch sub {
            case .all: return true
            case .alert: return kind == .botAlert
            case .push: return kind == .push
            case .routine: return kind != .botAlert && kind != .push
            }
        }
    }
}

@MainActor
final class ReaderModel: ObservableObject {
    struct RuleCount: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct Stats: Equatable {
        var inboxUnread = 0
        var importantUnread = 0
        /// 待处理的分组数
        var attention = 0
        /// 收件箱里还没读的例行机器人邮件数（可以一键清理）
        var routineUnread = 0
        var humanUnread = 0
    }

    @Published var mailbox: Mailbox = .allMail
    @Published var searchText = ""
    @Published var unreadOnly = false
    /// 只看某个来源（"github" / "jira" / "googleDocs" / "other"），nil 表示全部
    @Published var sourceFilter: String?
    /// 当前邮箱 / 搜索条件下各来源的分组数（列表顶部分类标签）
    @Published private(set) var sourceCounts: [String: SourceCount] = [:]
    /// 收件箱里各来源的分组数（侧栏"来源"）
    @Published private(set) var inboxSourceCounts: [String: SourceCount] = [:]
    /// 按 PR 聚合：同一个 PR 的评论、CI 结果、Jira 联动合成一行（默认开）
    @Published var groupByPR = UserDefaults.standard.object(forKey: Pref.groupByPR) as? Bool ?? true
    @Published var selectedThreadID: String?
    /// 右侧详情顶部的筛选，按分组记住（切到别的 PR 再回来还是上次的选择）
    @Published var detailFilters: [String: DetailFilter] = [:]
    @Published var showPalette = false
    /// 每 +1 请求一次搜索框获得焦点
    @Published var focusSearchTick = 0

    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var hasMore = false
    @Published private(set) var messages: [MessageDetail] = []
    /// 打开这个会话那一刻还没读的邮件。打开后很快会被自动标成已读，详情页靠它决定展开和定位哪几封
    @Published private(set) var openedUnreadIDs: Set<String> = []
    @Published private(set) var labels: [LabelInfo] = []
    @Published private(set) var ruleCounts: [RuleCount] = []
    /// 各来源分组里「其他」的未读分组数（key = 来源）
    @Published private(set) var restCounts: [String: Int] = [:]
    @Published private(set) var stats = Stats()
    /// 概览页用：最近的未读重点会话
    @Published private(set) var dashboard: [ThreadSummary] = []
    @Published private(set) var errorText: String?
    /// 本地邮件里学到的 Jira 站点域名，用来拼 /browse/KEY 链接
    @Published private(set) var jiraHost: String?
    /// 自动识别出的 GitHub 用户名（设置里没填时用它判断"有没有 @ 你"）
    @Published private(set) var detectedLogin: String?
    var mailTools: StoreMailTools? { service.store.map { StoreMailTools(store: $0) } }

    var githubLogin: String? {
        let manual = (UserDefaults.standard.string(forKey: Pref.githubLogin) ?? "").trimmingCharacters(in: .whitespaces)
        return manual.isEmpty ? detectedLogin : manual.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    /// 设置里填的 Jira 显示名（去掉开头的 @）；没填返回 nil。
    var jiraName: String? {
        let name = (UserDefaults.standard.string(forKey: Pref.jiraName) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@ ").union(.whitespaces))
        return name.isEmpty ? nil : name
    }

    /// 来源的显示顺序和样式。
    static let sourceOrder = ["github", "jira", "googleDocs", "other"]
    static func style(forSource source: String) -> (title: String, icon: String, color: String) {
        switch source {
        case "github": return ("GitHub", "brand.github", "blue")
        case "jira": return ("Jira", "brand.jira", "cyan")
        case "googleDocs": return ("文档", "brand.googleDocs", "green")
        default: return ("其他", "envelope", "gray")
        }
    }

    let service: MailService
    /// 今日概览里的 AI 助手（对话和简报）；换页面不丢
    let assistant = AssistantModel()
    private var cancellables = Set<AnyCancellable>()
    private let pageSize = 100
    private var limit = 100
    /// 从通知 / 菜单跳转过来时，等切换完邮箱再选中的会话
    private var pendingThreadID: String?
    /// 列表和详情都直接订阅数据库（见 MailCore/LiveQueries.swift）：数据一变就推过来，不用手动刷新
    private var listObservation: StoreObservation?
    private var messagesObservation: StoreObservation?
    /// 「延迟 N 秒标已读」的倒计时
    private var markTask: Task<Void, Never>?
    /// 在这个会话里手动标回了未读：直到换一个会话之前不再自动标已读
    private var autoMarkSuppressed = false

    init(service: MailService) {
        self.service = service

        // $xxx 在值真正改变之前发出，所以先 receive(on:) 到下一轮再读属性
        $mailbox.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            selectedThreadID = pendingThreadID
            pendingThreadID = nil
            scheduleReload()
        }.store(in: &cancellables)

        $searchText.dropFirst().removeDuplicates().debounce(for: .milliseconds(200), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleReload()
        }.store(in: &cancellables)

        $unreadOnly.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleReload()
        }.store(in: &cancellables)

        $sourceFilter.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleReload()
        }.store(in: &cancellables)

        $groupByPR.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] value in
            guard let self else { return }
            UserDefaults.standard.set(value, forKey: Pref.groupByPR)
            // 分组方式变了，选中的分组标识（prKey 或 threadId）不再对应列表里的行：换成同一封邮件在新分组下的标识
            if let id = selectedThreadID, let first = messages.last, let store = service.store {
                selectedThreadID = value ? (try? store.prKey(forThread: first.threadId)) ?? first.threadId : first.threadId
                _ = id
            }
            reloadThreads(resetPaging: true)
        }.store(in: &cancellables)

        $selectedThreadID.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.observeSelection()
        }.store(in: &cancellables)

        // 设置页里的开关改的是偏好，这里同步回来
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            let value = UserDefaults.standard.object(forKey: Pref.groupByPR) as? Bool ?? true
            if value != groupByPR { groupByPR = value }
        }.store(in: &cancellables)

        service.$revision.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.reloadAll()
        }.store(in: &cancellables)

        service.$navigation.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] request in
            self?.apply(request)
        }.store(in: &cancellables)
    }

    var rulesByName: [String: Rule] { Dictionary(service.rules.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }) }

    var selectedThread: ThreadSummary? { threads.first { $0.id == selectedThreadID } }

    // MARK: - Loading

    /// 侧栏计数、概览这些汇总数据（同步或标已读之后 revision +1 时重算）。列表和详情走数据库订阅，不在这里。
    private func reloadAll() {
        guard let store = service.store else {
            threads = []
            messages = []
            return
        }
        // 邮件库是后来才打开的（首次启动 / 重新登录）：这时才能开始订阅
        if listObservation == nil { reloadThreads(resetPaging: false) }
        if messagesObservation == nil, selectedThreadID != nil { observeSelection() }
        do {
            labels = try store.labels()
            let counts = try store.unreadMatchCounts().map { RuleCount(name: $0.name, count: $0.count) }
            if counts != ruleCounts { ruleCounts = counts }
            let enabled = service.rules.filter(\.enabled)
            var rest: [String: Int] = [:]
            for (source, rules) in Dictionary(grouping: enabled, by: RuleGrouping.key) where source != "other" {
                rest[source] = try store.unreadThreadCount(in: .sourceRest(source: source, excluding: rules.map(\.name)))
            }
            if rest != restCounts { restCounts = rest }
            let newStats = Stats(inboxUnread: try store.unreadThreadCount(in: .label("INBOX")),
                                 importantUnread: try store.unreadThreadCount(in: .important),
                                 attention: try store.attentionCount(groupByPR: true),
                                 routineUnread: try store.unreadMessageIDs(kind: .botRoutine).count,
                                 humanUnread: try store.unreadMessageIDs(kind: .human).count)
            if newStats != stats { stats = newStats }
            inboxSourceCounts = try store.sourceCounts(in: .label("INBOX"), groupByPR: true)
            jiraHost = try store.jiraHost()
            let login = try store.detectedGitHubLogin()
            if login != detectedLogin { detectedLogin = login }
            let top = try store.threads(in: .attention, groupByPR: true, limit: 8)
            if top != dashboard { dashboard = top }
        } catch {
            trace("[ReloadAll] 出错：%@", error.localizedDescription)
            errorText = error.localizedDescription
        }
    }

    /// 切换邮箱时会同时改 mailbox / sourceFilter / searchText，每个都会触发一次重新加载；合并成下一轮只加载一次
    /// （每次加载都要在主线程查库并重建整个列表，重复做就是"卡"）。
    private var reloadScheduled = false
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reloadScheduled = false
            reloadThreads(resetPaging: true)
        }
    }

    /// 按当前条件（重新）订阅列表。条件或分页变了才需要调用，数据变化会自动推过来。
    func reloadThreads(resetPaging: Bool) {
        guard let store = service.store else { return }
        if resetPaging { limit = pageSize }
        listObservation?.cancel()
        let query = ThreadQuery(mailbox: mailbox, search: searchText, unreadOnly: unreadOnly, source: sourceFilter,
                                groupByPR: groupByPR, limit: limit)
        listObservation = store.observeList(query, onError: { [weak self] error in
            trace("[List] 出错：%@", error.localizedDescription)
            self?.errorText = error.localizedDescription
        }) { [weak self] snapshot in
            self?.applyList(snapshot)
        }
    }

    private func applyList(_ snapshot: ListSnapshot) {
        if snapshot.threads != threads { threads = snapshot.threads }
        if snapshot.hasMore != hasMore { hasMore = snapshot.hasMore }
        if snapshot.sourceCounts != sourceCounts { sourceCounts = snapshot.sourceCounts }
        errorText = nil
        #if DEBUG
        // 调试用：`open MailBar.app --args -selectFirstThread YES` 启动后自动选中第一个会话，方便截图检查详情页
        if selectedThreadID == nil, UserDefaults.standard.bool(forKey: "selectFirstThread"), let first = threads.first {
            selectedThreadID = first.id
        }
        // `--args -selectGroup Vungle/Monetize#7109`：直接选中指定的 PR 分组
        if selectedThreadID == nil, let group = UserDefaults.standard.string(forKey: "selectGroup") { selectedThreadID = group }
        #endif
    }

    func loadMore() {
        guard hasMore else { return }
        limit += pageSize
        reloadThreads(resetPaging: false)
    }

    /// 选中的会话变了：换订阅它的邮件。每次推来新内容（包括看着的时候来了新邮件）都检查一次要不要自动标已读。
    private func observeSelection() {
        messagesObservation?.cancel()
        messagesObservation = nil
        markTask?.cancel()
        markTask = nil
        autoMarkSuppressed = false
        guard let id = selectedThreadID, let store = service.store else {
            if !messages.isEmpty { messages = [] }
            openedUnreadIDs = []
            return
        }
        var first = true
        messagesObservation = store.observeMessages(inGroup: id, onError: { error in
            trace("[Detail] 出错：%@", error.localizedDescription)
        }) { [weak self] loaded in
            guard let self, self.selectedThreadID == id else { return }
            if first {
                // 先记下打开时的未读，再去自动标已读
                first = false
                self.openedUnreadIDs = Set(loaded.filter(\.isUnread).map(\.id))
            }
            if loaded != self.messages { self.messages = loaded }
            self.autoMarkIfNeeded()
        }
    }

    // MARK: - Keyboard / selection

    func moveSelection(by delta: Int) {
        let rows = visibleThreads
        guard !rows.isEmpty else { return }
        if let current = rows.firstIndex(where: { $0.id == selectedThreadID }) {
            selectedThreadID = rows[min(max(current + delta, 0), rows.count - 1)].id
        } else {
            selectedThreadID = delta > 0 ? rows.first?.id : rows.last?.id
        }
    }

    func select(_ mailbox: Mailbox) {
        searchText = ""
        sourceFilter = nil
        self.mailbox = mailbox
    }

    /// 侧栏"来源"：回到收件箱并只看这个来源。
    func selectSource(_ source: String) {
        searchText = ""
        if mailbox != .label("INBOX") { mailbox = .label("INBOX") }
        sourceFilter = source
    }

    // MARK: - List order

    /// 列表就是按邮件时间从新到旧排，已读 / 未读不影响顺序：点一行变成已读，它留在原地。
    /// j/k 移动和加载更多都按它来。
    var visibleThreads: [ThreadSummary] { threads }

    /// 一键清理：把收件箱里所有未读的例行机器人邮件标为已读。
    func cleanRoutine() {
        guard let store = service.store, let ids = try? store.unreadMessageIDs(kind: .botRoutine), !ids.isEmpty else { return }
        Task { await service.setRead(true, messageIds: ids) }
    }

    // MARK: - Read state

    var selectedThreadHasUnread: Bool { messages.contains { $0.isUnread } }

    /// 打开的会话里还有未读，就按设置把它们标为已读。
    /// 标已读会先改本地（同一个事务），订阅马上推来已读的结果，这里就不会重复标；所以不需要额外的去重标记。
    private func autoMarkIfNeeded() {
        guard Pref.markRead != .manual, service.canModify, !autoMarkSuppressed, selectedThreadID != nil, !unreadToMark.isEmpty else { return }
        guard Pref.markRead == .afterDelay else { return markNow() }
        guard markTask == nil else { return }       // 已经在倒计时
        let id = selectedThreadID
        let delay = UInt64(Pref.markReadDelaySeconds) * 1_000_000_000
        markTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.selectedThreadID == id else { return }
            self.markTask = nil
            if !self.autoMarkSuppressed { self.markNow() }
        }
    }

    /// 会话以时间线展示，所有邮件都在眼前；"只标记当前这封"时只标最新的一封。
    private var unreadToMark: [String] {
        guard let latest = messages.last else { return [] }
        return Pref.markWholeThread ? messages.filter(\.isUnread).map(\.id) : (latest.isUnread ? [latest.id] : [])
    }

    private func markNow() {
        let ids = unreadToMark
        guard !ids.isEmpty else { return }
        trace("[AutoMark] thread=%@ 要标已读=%d", selectedThreadID ?? "-", ids.count)
        Task { await service.setRead(true, messageIds: ids) }
    }

    /// 手动切换：会话里有未读就全部标为已读，否则把最新一封标为未读。
    func toggleRead(threadId: String) {
        guard let store = service.store else { return }
        let all = (try? store.messages(inGroup: threadId)) ?? []
        let unread = all.filter(\.isUnread)
        if threadId == selectedThreadID {
            markTask?.cancel()
            markTask = nil
            // 手动标回未读：看着这个会话期间别再自动标已读
            if unread.isEmpty { autoMarkSuppressed = true }
        }
        Task {
            if !unread.isEmpty {
                await service.setRead(true, messageIds: unread.map(\.id))
            } else if let last = all.last {
                await service.setRead(false, messageIds: [last.id])
            }
        }
    }

    // MARK: - Notification services (GitHub / Jira / Google 文档)

    /// "在原服务里打开"：服务名、图标、链接。
    struct ServiceLink {
        let name: String
        let icon: String
        let url: URL
    }

    /// 当前选中分组的通知信息：取最新一封能识别、且带编号的（GitHub 评论），否则最新一封能识别的。
    var primaryInfo: NotificationInfo? {
        let infos = messages.reversed().compactMap(info(for:))
        return infos.first { $0.reference != nil } ?? infos.first
    }

    func info(for message: MessageDetail) -> NotificationInfo? {
        NotificationClassifier.classify(subject: message.subject, from: message.from, reason: message.reason, body: String(message.snippet.prefix(600)))
    }

    /// 选中分组对应的原服务链接。按 PR 聚合的分组直接用 prKey 拼 GitHub 地址。
    func serviceLink() -> ServiceLink? {
        if let id = selectedThreadID, let key = GitHubSubject.splitPRKey(id), let url = URL(string: "https://github.com/\(key.repo)/pull/\(key.number)") {
            return ServiceLink(name: "GitHub", icon: "brand.github", url: url)
        }
        guard let info = primaryInfo else { return nil }
        let bodies = messages.suffix(4).flatMap { [$0.bodyText, $0.bodyHtml ?? ""] }
        guard let url = NotificationLinks.url(for: info, jiraHost: jiraHost, bodies: bodies) else { return nil }
        return ServiceLink(name: info.service.displayName, icon: Self.icon(for: info.service), url: url)
    }

    /// 这个 Jira 编号在 Jira 里的地址（需要先从邮件里学到站点域名）。
    func jiraURL(forKey key: String) -> URL? {
        jiraHost.flatMap { URL(string: "https://\($0)/browse/\(key)") }
    }

    static func icon(for service: NotificationInfo.Service) -> String {
        switch service {
        case .github: return "brand.github"
        case .jira: return "brand.jira"
        case .googleDocs: return "brand.googleDocs"
        }
    }

    /// 通知邮件里给 Gmail 会话 id 的跳转（点通知、点菜单），换成列表当前分组方式下的标识。
    private func resolveGroup(forThread threadId: String) -> String {
        guard groupByPR, let store = service.store else { return threadId }
        return (try? store.prKey(forThread: threadId)) ?? threadId
    }

    // MARK: - Navigation

    private func apply(_ request: NavigationRequest) {
        // 指定了邮箱就回到那个邮箱的完整列表（来源筛选会把目标邮件藏起来）
        if request.mailbox != nil { sourceFilter = nil }
        if let target = request.mailbox, target != mailbox {
            searchText = ""
            pendingThreadID = request.threadId.map(resolveGroup(forThread:))
            mailbox = target
        } else if let threadId = request.threadId {
            selectedThreadID = resolveGroup(forThread: threadId)
        }
        service.consumeNavigation(request)
    }
}

/// 诊断日志：追加写到 ~/Library/Logs/MailBar-trace.log（统一日志会把字符串参数遮成 <private>，排查时看不到内容）。
func trace(_ format: String, _ args: CVarArg...) {
    #if DEBUG
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] " + String(format: format, arguments: args) + "\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MailBar-trace.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}
