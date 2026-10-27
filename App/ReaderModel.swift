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

    /// 列表里的一个分段：来源 + 分诊层级（需要处理 / 有新动态 / 仅机器人更新 / 其余）。
    struct ListSection: Identifiable {
        let id: String
        let title: String
        let icon: String
        let colorName: String
        let threads: [ThreadSummary]
        /// 默认折叠（只有例行机器人更新的 PR）
        let collapsedByDefault: Bool
        /// 这一段里有一键清理
        let cleanable: Bool
        var unread: Int { threads.filter(\.isUnread).count }
    }

    @Published var mailbox: Mailbox = Pref.landingIsAttention ? .attention : .label("INBOX")
    @Published var searchText = ""
    @Published var unreadOnly = false
    /// 只看某个来源（"github" / "jira" / "googleDocs" / "other"），nil 表示全部
    @Published var sourceFilter: String?
    /// 当前邮箱 / 搜索条件下各来源的分组数（列表顶部分类标签）
    @Published private(set) var sourceCounts: [String: SourceCount] = [:]
    /// 收件箱里各来源的分组数（侧栏"来源"）
    @Published private(set) var inboxSourceCounts: [String: SourceCount] = [:]
    /// 用户手动展开 / 折叠过的分段；没出现在这里的按 collapsedByDefault
    @Published var sectionOverrides: [String: Bool] = [:]
    /// 按 PR 聚合：同一个 PR 的评论、CI 结果、Jira 联动合成一行（默认开）
    @Published var groupByPR = UserDefaults.standard.object(forKey: Pref.groupByPR) as? Bool ?? true
    @Published var selectedThreadID: String?
    /// 右侧详情顶部的筛选，按分组记住（切到别的 PR 再回来还是上次的选择）
    @Published var detailFilters: [String: DetailFilter] = [:]
    /// 看过的行：标为已读后不立刻挪位置、不立刻消失，记下它所在的分段，等退出这个列表（换邮箱 / 筛选 / 搜索）或手动刷新再整理
    private var stickySections: [String: String] = [:]
    @Published var showPalette = false
    /// 每 +1 请求一次搜索框获得焦点
    @Published var focusSearchTick = 0

    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var hasMore = false
    @Published private(set) var messages: [MessageDetail] = []
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
    private var cancellables = Set<AnyCancellable>()
    private let pageSize = 100
    private var limit = 100
    /// 从通知 / 菜单跳转过来时，等切换完邮箱再选中的会话
    private var pendingThreadID: String?
    private var markTask: Task<Void, Never>?
    /// 上一次触发自动标记已读的会话|邮件：只在选中项变化时标记，避免用户手动标回未读后又被改回已读
    private var lastAutoMarkKey: String?

    init(service: MailService) {
        self.service = service

        // $xxx 在值真正改变之前发出，所以先 receive(on:) 到下一轮再读属性
        $mailbox.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            selectedThreadID = pendingThreadID
            pendingThreadID = nil
            reloadThreads(resetPaging: true)
        }.store(in: &cancellables)

        $searchText.dropFirst().removeDuplicates().debounce(for: .milliseconds(200), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.reloadThreads(resetPaging: true)
        }.store(in: &cancellables)

        $unreadOnly.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.reloadThreads(resetPaging: true)
        }.store(in: &cancellables)

        $sourceFilter.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.reloadThreads(resetPaging: true)
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
            guard let self else { return }
            // 选中过的行"粘住"：之后标为已读也留在原位，直到退出列表或手动刷新
            if let current = selectedThread, stickySections[current.id] == nil { stickySections[current.id] = sectionID(of: current) }
            loadMessages()
        }.store(in: &cancellables)

        // 设置页里的开关改的是偏好，这里同步回来
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            let value = UserDefaults.standard.object(forKey: Pref.groupByPR) as? Bool ?? true
            if value != groupByPR { groupByPR = value }
        }.store(in: &cancellables)

        service.$settleTick.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, !stickySections.isEmpty else { return }
            stickySections = [:]
            reloadThreads(resetPaging: false)
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

    private func reloadAll() {
        guard let store = service.store else {
            threads = []
            messages = []
            return
        }
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
            errorText = error.localizedDescription
        }
        reloadThreads(resetPaging: false)
        loadMessages()
    }

    func reloadThreads(resetPaging: Bool) {
        guard let store = service.store else { return }
        if resetPaging { limit = pageSize; stickySections = [:] }
        do {
            // 多取一条用来判断还有没有下一页
            let rows = try store.threads(in: mailbox, search: searchText, unreadOnly: unreadOnly, source: sourceFilter,
                                         groupByPR: groupByPR, limit: limit + 1)
            sourceCounts = try store.sourceCounts(in: mailbox, search: searchText, groupByPR: groupByPR)
            hasMore = rows.count > limit
            var page = Array(rows.prefix(limit))
            // 看过的行因为状态变化（比如刚被标为已读）不再满足当前筛选时，留在原位，等退出列表或手动刷新再消失
            if !resetPaging, !stickySections.isEmpty {
                let present = Set(page.map(\.id))
                for (index, row) in threads.enumerated() where stickySections[row.id] != nil && !present.contains(row.id) {
                    page.insert(row.markedRead(), at: min(index, page.count))
                }
            }
            if page != threads { threads = page }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
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

    private func loadMessages() {
        guard let id = selectedThreadID, let store = service.store else {
            if !messages.isEmpty { messages = [] }
            return
        }
        let loaded = (try? store.messages(inGroup: id)) ?? []
        if loaded != messages { messages = loaded }
        scheduleAutoMarkRead()
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

    // MARK: - Sections (triage)

    /// 把列表分成：来源 × 分诊层级。GitHub 按"需要处理 / 有新动态 / 仅机器人更新 / 其余"分层，其他来源各一段。
    var sections: [ListSection] {
        if mailbox == .attention {
            return threads.isEmpty ? [] : [ListSection(id: "attention", title: "待处理", icon: "exclamationmark.bubble.fill", colorName: "orange",
                                                     threads: threads, collapsedByDefault: false, cleanable: false)]
        }
        var result: [ListSection] = []
        func add(_ id: String, _ title: String, _ icon: String, _ color: String, _ rows: [ThreadSummary], collapsed: Bool = false, cleanable: Bool = false) {
            if !rows.isEmpty { result.append(ListSection(id: id, title: title, icon: icon, colorName: color, threads: rows, collapsedByDefault: collapsed, cleanable: cleanable)) }
        }
        func rows(_ id: String) -> [ThreadSummary] { threads.filter { effectiveSectionID(of: $0) == id } }
        add("github.attention", "GitHub · 需要处理", "exclamationmark.bubble.fill", "orange", rows("github.attention"))
        add("github.activity", "GitHub · 有新动态", "text.bubble", "blue", rows("github.activity"))
        add("github.routine", "GitHub · 仅机器人更新", "gearshape.2", "gray", rows("github.routine"), collapsed: true, cleanable: true)
        add("github.read", "GitHub · 已读", "checkmark.circle", "gray", rows("github.read"))
        add("jira", "Jira", "checklist", "cyan", rows("jira"))
        add("googleDocs", "Google 文档", "doc.text", "green", rows("googleDocs"))
        add("other", "其他邮件", "envelope", "gray", rows("other"))
        return result
    }

    /// 一行按当前状态应该落在哪个分段。
    private func sectionID(of t: ThreadSummary) -> String {
        guard t.source == "github" else { return t.source }
        if t.needsAttention { return "github.attention" }
        if t.humanUnread > 0 { return "github.activity" }
        return t.unreadCount > 0 ? "github.routine" : "github.read"
    }

    /// 看过的行沿用当时的分段，其余按当前状态。
    private func effectiveSectionID(of t: ThreadSummary) -> String {
        stickySections[t.id] ?? sectionID(of: t)
    }

    func isCollapsed(_ section: ListSection) -> Bool {
        sectionOverrides[section.id] ?? section.collapsedByDefault
    }

    func toggleSection(_ section: ListSection) {
        sectionOverrides[section.id] = !isCollapsed(section)
    }

    /// 按当前分段顺序、跳过折叠段的行：j/k 移动和加载更多都按它来。
    var visibleThreads: [ThreadSummary] {
        sections.filter { !isCollapsed($0) }.flatMap(\.threads)
    }

    /// 一键清理：把收件箱里所有未读的例行机器人邮件标为已读。
    func cleanRoutine() {
        guard let store = service.store, let ids = try? store.unreadMessageIDs(kind: .botRoutine), !ids.isEmpty else { return }
        Task { await service.setRead(true, messageIds: ids) }
    }

    // MARK: - Read state

    var selectedThreadHasUnread: Bool { messages.contains { $0.isUnread } }

    /// 按设置在查看邮件后把它（或整个会话）标为已读。
    private func scheduleAutoMarkRead() {
        guard Pref.markRead != .manual, service.canModify, let threadId = selectedThreadID, let latest = messages.last else { return }
        guard threadId != lastAutoMarkKey else { return }
        lastAutoMarkKey = threadId

        // 会话以时间线展示，所有邮件都在眼前；"只标记当前这封"时只标最新的一封
        let ids = Pref.markWholeThread ? messages.filter(\.isUnread).map(\.id) : (latest.isUnread ? [latest.id] : [])
        guard !ids.isEmpty else { return }
        markTask?.cancel()
        let delay = Pref.markRead == .afterDelay ? Pref.markReadDelaySeconds : 0
        markTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
            guard !Task.isCancelled, let self, self.selectedThreadID == threadId else { return }
            await self.service.setRead(true, messageIds: ids)
        }
    }

    /// 手动切换：会话里有未读就全部标为已读，否则把最新一封标为未读。
    func toggleRead(threadId: String) {
        guard let store = service.store else { return }
        let all = (try? store.messages(inGroup: threadId)) ?? []
        let unread = all.filter(\.isUnread)
        if threadId == selectedThreadID { markTask?.cancel() }
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
