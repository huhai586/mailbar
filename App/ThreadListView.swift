import MailCore
import SwiftUI

struct ThreadListView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService
    @AppStorage(Pref.loadOlderBatch) private var olderBatch = 50
    @AppStorage(Pref.uiDensity) private var density = "standard"
    @AppStorage(Pref.showSnippets) private var showSnippets = true
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var dayGroups = DayGroupCache()
    /// 列表最上面那一行（滚动位置）；新邮件插到上面时用它保持眼前的内容不动
    @State private var topRowID: String?

    private var title: String { SystemMailbox.title(for: reader.mailbox, labels: reader.labels) }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .background(Theme.bg)
        .onChange(of: reader.focusSearchTick) { searchFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SidebarToggleButton()
                Text(title).font(Theme.ui(15, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(reader.threads.isEmpty ? "" : "\(reader.threads.count)\(reader.hasMore ? "+" : "")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                Spacer()
                groupToggle
                filterToggle
                Button { service.manualSync() } label: {
                    SyncIcon(syncing: service.syncing).font(.system(size: 12)).iconHitTarget()
                }
                .buttonStyle(PlainPointerButtonStyle())
                .foregroundStyle(Theme.muted)
                .pointerStyle(.link)
                .help("立即收取邮件（⌘R）")
                .accessibilityLabel("立即收取邮件")
            }
            sourceTabs
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("搜索邮件   按 / 聚焦", text: $reader.searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .focused($searchFocused)
                    .onSubmit { listFocused = true }
                    .onKeyPress(.escape) {
                        reader.searchText = ""
                        listFocused = true
                        return .handled
                    }
                if !reader.searchText.isEmpty {
                    Button { reader.searchText = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(PlainPointerButtonStyle()).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(searchFocused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// 来源分类标签：全部 / GitHub / Jira / 文档 / 其他，数字只表示有未读的分组数，没有未读就不显示数字。
    private var sourceTabs: some View {
        let counts = reader.sourceCounts
        let all = counts.values.reduce((groups: 0, unread: 0)) { ($0.groups + $1.groups, $0.unread + $1.unreadGroups) }
        return HStack(spacing: 4) {
            tab("全部", icon: nil, color: Theme.muted, source: nil, number: all.unread, highlight: true)
            ForEach(ReaderModel.sourceOrder, id: \.self) { source in
                if let count = counts[source], count.groups > 0 {
                    let style = ReaderModel.style(forSource: source)
                    tab(style.title, icon: style.icon, color: Theme.color(named: style.color), source: source,
                        number: count.unreadGroups, highlight: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tab(_ title: String, icon: String?, color: Color, source: String?, number: Int, highlight: Bool) -> some View {
        let active = reader.sourceFilter == source
        return Button { reader.sourceFilter = source } label: {
            HStack(spacing: 4) {
                if let icon { IconImage(name: icon, size: 9.5).foregroundStyle(active ? color : Theme.faint) }
                Text(title).font(Theme.ui(11.5, active ? .semibold : .regular))
                if number > 0 { Text("\(number)").font(Theme.mono(10)).foregroundStyle(highlight ? color : Theme.faint) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .foregroundStyle(active ? Theme.text : Theme.muted)
            .background(active ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Color.clear : Theme.border.opacity(0.7), lineWidth: 0.5))
        }
        .buttonStyle(PlainPointerButtonStyle())
    }

    /// 列表按"会话"还是按"PR"分组：PR 模式下同一个 PR 的评论、CI 结果、Jira 联动合成一行。
    private var groupToggle: some View {
        HStack(spacing: 0) {
            filterButton("会话", active: !reader.groupByPR) { reader.groupByPR = false }
            filterButton("PR", active: reader.groupByPR) { reader.groupByPR = true }
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 0.5))
        .help("按 PR 聚合：同一个 PR 的评论、CI 结果、Jira 联动合成一行（p）")
    }

    private var filterToggle: some View {
        HStack(spacing: 0) {
            filterButton("全部", active: !reader.unreadOnly) { reader.unreadOnly = false }
            filterButton("未读", active: reader.unreadOnly) { reader.unreadOnly = true }
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 0.5))
        .help("只看未读（u）")
    }

    private func filterButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.ui(11, .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .foregroundStyle(active ? Theme.text : Theme.muted)
                .background(active ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(PlainPointerButtonStyle())
    }

    /// 同一天（按最后更新时间）的会话。
    struct DayGroup: Identifiable {
        let id: String
        let title: String
        let threads: [ThreadSummary]
        let unread: Int

        static func make(_ threads: [ThreadSummary]) -> [DayGroup] {
            var groups: [DayGroup] = []
            var key = ""
            var title = ""
            var current: [ThreadSummary] = []
            func flush() {
                guard !current.isEmpty else { return }
                groups.append(DayGroup(id: key, title: title, threads: current, unread: current.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }))
            }
            for thread in threads {
                let k = DateText.dayKey(thread.date)
                if k != key || current.isEmpty {
                    flush()
                    key = k
                    title = DateText.day(thread.date)
                    current = []
                }
                current.append(thread)
            }
            flush()
            return groups
        }
    }

    /// 分组结果缓存：列表数据没变（reader.threadsVersion 没变）、也没跨过午夜时，重绘直接用上次的分组，
    /// 不用对每一行再算一遍日期。选中一行、悬停、输入搜索词这些只触发重绘、不改数据的操作都会受益。
    final class DayGroupCache {
        private var version = -1
        private var today = Date.distantPast
        private var groups: [DayGroup] = []

        func groups(for threads: [ThreadSummary], version: Int) -> [DayGroup] {
            let startOfToday = Calendar.current.startOfDay(for: Date())
            if version != self.version || startOfToday != today {
                groups = DayGroup.make(threads)
                self.version = version
                today = startOfToday
            }
            return groups
        }
    }

    /// 行的标识里带上会变的状态：已读 / 未读变了就换一个新的行视图。
    /// 只用 thread.id 时，LazyVStack 在「行换了位置、内容同时变了」时会继续显示旧内容（标成已读后那一行还是未读的样子）。
    static func rowKey(_ t: ThreadSummary) -> String {
        "\(t.id)|\(t.unreadCount)|\(t.humanUnread)|\(t.alertUnread)|\(t.routineUnread)"
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    let rules = reader.rulesByName
                    let visible = reader.visibleThreads
                    // 按最后更新的日期分组：今天 / 昨天 / 星期一 10月26日……组标题吸顶，一眼分清新旧
                    ForEach(dayGroups.groups(for: reader.threads, version: reader.threadsVersion)) { group in
                    Section {
                    ForEach(group.threads) { thread in
                        // 外层按 thread.id 认行（滚动定位用），里层按状态认：已读 / 未读一变就换新的行视图，
                        // 不然 LazyVStack 在「行的位置和内容同时变」时会继续显示旧内容
                        VStack(spacing: 0) {
                            ThreadRow(thread: thread, selected: thread.id == reader.selectedThreadID, rules: rules,
                                      viewingRule: { if case .rule(let name) = reader.mailbox { return name } else { return nil } }(),
                                      compact: density != "spacious", showSnippet: showSnippets, highlight: reader.highlightQuery)
                                .id(Self.rowKey(thread))
                        }
                            .onTapGesture {
                                trace("[Tap] id=%@ 未读=%d 当前选中=%@", thread.id, thread.unreadCount, reader.selectedThreadID ?? "-")
                                reader.selectedThreadID = thread.id
                                listFocused = true
                            }
                            .contextMenu {
                                Button(thread.isUnread ? "标为已读" : "标为未读") { reader.toggleRead(threadId: thread.id) }
                                if let url = ThreadRow.githubURL(for: thread) {
                                    Button("在 GitHub 中打开") { NSWorkspace.shared.open(url) }
                                }
                                Button("在 Gmail 中打开") { NSWorkspace.shared.open(gmailURL(threadId: thread.latestThreadId, account: service.accountEmail)) }
                            }
                            .onAppear { if thread.id == visible.last?.id { reader.loadMore() } }
                    }
                    } header: {
                        DayHeader(title: group.title, count: group.threads.count, unread: group.unread)
                            .id("day-\(group.id)")
                    }
                    }
                    if !reader.threads.isEmpty, !reader.hasMore, reader.searchText.isEmpty { olderFooter }
                }
                .scrollTargetLayout()
            }
            // 新邮件到了不打乱正在看的位置：停在最顶上时跟着显示最新的；往下翻着时，眼前这一行保持不动
            .scrollPosition(id: $topRowID, anchor: .top)
            .onChange(of: reader.threads.map(\.id)) { old, new in
                // 停在最顶上（或还没滚动过）：新邮件来了就回到顶部，连同「今天」的标题一起露出来；
                // 往下翻着时不动它，scrollPosition 会让眼前那一行保持在原处
                guard topRowID == nil || topRowID == old.first, let first = new.first,
                      let day = reader.threads.first.map({ DateText.dayKey($0.date) }) else { return }
                _ = first
                DispatchQueue.main.async { proxy.scrollTo("day-\(day)", anchor: .top) }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(phases: .down) { handleKey($0) }
            .onChange(of: reader.selectedThreadID) { _, id in
                // 只有键盘 / 菜单移动选中项时才把它滚进视野；点击选中不滚动，滚动始终由用户自己控制
                guard reader.scrollSelectionIntoView else { return }
                reader.scrollSelectionIntoView = false
                if let id { proxy.scrollTo(id) }
            }
            .overlay { if reader.threads.isEmpty { emptyState } }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        switch press.key {
        case .downArrow: reader.moveSelection(by: 1)
        case .upArrow: reader.moveSelection(by: -1)
        default:
            switch press.characters {
            case "j": reader.moveSelection(by: 1)
            case "k": reader.moveSelection(by: -1)
            case "m": if let id = reader.selectedThreadID { reader.toggleRead(threadId: id) }
            case "u": reader.unreadOnly.toggle()
            case "r": service.manualSync()
            case "/": reader.focusSearchTick += 1
            case "p": reader.groupByPR.toggle()
            case "o":
                NSWorkspace.shared.open(gmailURL(threadId: reader.selectedThread?.latestThreadId ?? reader.selectedThreadID, account: service.accountEmail))
            case "g":
                if let link = reader.serviceLink() { NSWorkspace.shared.open(link.url) }
            default: return .ignored
            }
        }
        return .handled
    }

    /// 列表滚到底（这一行进入视野）就自动再拉一批；已经到头了就只显示提示。
    private var olderFooter: some View {
        HStack(spacing: 6) {
            Spacer()
            if service.noMoreOlder {
                Text("没有更早的邮件了").font(Theme.mono(11)).foregroundStyle(Theme.faint)
            } else {
                if service.loadingOlder { ProgressView().controlSize(.small) }
                Button(service.loadingOlder ? "正在加载更早的邮件…" : "加载更早的邮件（再拉 \(olderBatch) 封）") {
                    Task { await service.loadOlder(count: olderBatch) }
                }
                .disabled(service.loadingOlder)
                .buttonStyle(PlainPointerButtonStyle())
                .font(Theme.mono(11))
                .foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .onAppear {
            // 列表太短（比如某个筛选只有几封）时不自动拉，免得一直往前翻整个邮箱
            guard reader.threads.count >= 20, !service.loadingOlder, !service.noMoreOlder else { return }
            Task { await service.loadOlder(count: olderBatch) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: reader.mailbox == .attention ? "checkmark.seal" : (reader.searchText.isEmpty ? "tray" : "magnifyingglass"))
                .font(.system(size: 30))
                .foregroundStyle(reader.mailbox == .attention ? Theme.green : Theme.faint)
            if let error = reader.errorText {
                Text(error).font(.callout).foregroundStyle(Theme.red)
            } else if reader.mailbox == .attention {
                Text("没有待处理的邮件 🎉").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                Button("查看收件箱") { reader.select(.label("INBOX")) }.controlSize(.small)
            } else {
                Text(reader.searchText.isEmpty ? (reader.unreadOnly ? "没有未读邮件 🎉" : "这里没有邮件") : "没有找到匹配的邮件")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - Row

private struct ThreadRow: View {
    let thread: ThreadSummary
    let selected: Bool
    let rules: [String: Rule]
    /// 正在看的规则（侧栏点了某条规则）：列表里每一行都命中它，不用再重复显示这个标签
    var viewingRule: String?
    let compact: Bool
    let showSnippet: Bool
    /// 搜索词：标题和正文概览里高亮
    var highlight: String?
    @State private var hovering = false

    /// PR 分组用 PR 自己的最新一封 GitHub 邮件来识别标题和编号，不被最新一封是 Jira / 机器人带偏。
    private var info: NotificationInfo? {
        // 识别要跑一堆正则（每行约 75 微秒），而行的内容没变时结果也不变：按（会话、最后更新时间、未读数）缓存，滚动和重绘不再重算
        let key = "\(thread.id)|\(thread.date.timeIntervalSince1970)|\(thread.unreadCount)|\(thread.reasons.joined(separator: ","))" as NSString
        if let cached = Self.infoCache.object(forKey: key) { return cached.value }
        let value = NotificationClassifier.classify(subject: thread.prSubject ?? thread.subject, from: thread.from,
                                                    reason: Self.relation(thread.reasons) ?? thread.reason, body: thread.snippet)
        Self.infoCache.setObject(InfoBox(value), forKey: key)
        return value
    }

    private final class InfoBox { let value: NotificationInfo?; init(_ value: NotificationInfo?) { self.value = value } }
    private static let infoCache: NSCache<NSString, InfoBox> = {
        let cache = NSCache<NSString, InfoBox>()
        cache.countLimit = 2000
        return cache
    }()

    /// 你和这个 PR 最重要的关系。
    private static func relation(_ reasons: [String]) -> String? {
        ["review_requested", "mention", "team_mention", "assign", "security_alert", "author", "invitation", "ci_activity", "state_change"]
            .first { reasons.contains($0) }
    }

    static func githubURL(for thread: ThreadSummary) -> URL? {
        if let key = thread.prKey.flatMap(GitHubSubject.splitPRKey) { return URL(string: "https://github.com/\(key.repo)/pull/\(key.number)") }
        return GitHubSubject.parse(thread.subject)?.url
    }

    /// 命中的规则，重要的在前
    private var matched: [Rule] {
        thread.ruleNames.compactMap { rules[$0] }.sorted {
            Theme.priority(of: $0) != Theme.priority(of: $1) ? Theme.priority(of: $0) > Theme.priority(of: $1) : $0.name < $1.name
        }
    }

    private var isPR: Bool { thread.source == "github" }

    /// 未读行统一用一种底色（每个主题各一套，见 Theme.unreadFill）。不再按「出问题 / 待处理」分颜色：
    /// 出问题的可能是别人的 PR，和你无关，用颜色强调反而误导。左侧竖线只留给「选中」，行高也不变。

    /// 谁最近动了：优先真人（最新一封往往是机器人）。
    private var actor: String {
        let from = isPR ? (thread.lastHumanFrom ?? thread.from) : thread.from
        return MailAddress.parse(from).displayName
    }

    @Environment(\.colorScheme) private var scheme

    /// 真正算"未读"的：有真人 / 出问题 / 非 PR 的未读；只剩例行机器人未读的 PR 当作已读。
    private var unread: Bool { thread.isUnread && !(thread.onlyRoutineUnread && isPR) }

    /// PR 行底部：PR 号 + 已有多少条真人评论（没有真人评论就只显示 PR 号；有新的未读评论用强调色标出来）。
    @ViewBuilder
    private func commentsLine(_ info: NotificationInfo?) -> some View {
        let number = info?.reference.map { $0.replacingOccurrences(of: "PR ", with: "") }
        if number != nil || thread.humanCount > 0 {
            HStack(spacing: 10) {
                if let number { Text(number).foregroundStyle(Theme.faint) }
                if thread.humanCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: thread.humanUnread > 0 ? "text.bubble.fill" : "text.bubble").font(.system(size: 10)).frame(width: 12, height: 12)
                        Text(thread.humanUnread > 0 ? "\(thread.humanCount) 条真人评论 · \(thread.humanUnread) 条新" : "\(thread.humanCount) 条真人评论")
                    }
                    .foregroundStyle(thread.humanUnread > 0 ? Theme.accent : Theme.muted)
                    .fontWeight(.medium)
                    .lineLimit(1)
                }
            }
            .font(Theme.mono(11))
        }
    }

    private var important: Bool { thread.humanUnread > 0 || thread.alertUnread > 0 || (!isPR && thread.isUnread) }

    var body: some View {
        let info = info
        let title = info?.title ?? thread.subject
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: 3)
            ServiceIcon(source: thread.source, size: 15, color: unread ? Theme.accent : Theme.faint)
                .frame(width: 28, height: 28)
                .background(unread ? Theme.accent.opacity(0.16) : Theme.raised.opacity(0.5), in: Circle())
                .padding(.leading, 12)
                .padding(.top, Theme.pad(compact ? 9 : 11))   // 和右边文字块同样的上边距：图标顶端对齐标题顶端
            VStack(alignment: .leading, spacing: Theme.pad(compact ? 3 : 5)) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // 未读圆点：有真人 / 出问题的未读是强调色；只有例行机器人未读是灰点
                    Circle()
                        .fill(thread.isUnread ? (unread ? Theme.accent : Theme.faint) : .clear)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    Text(Highlight.text(title.isEmpty ? "（无主题）" : title, query: highlight))
                        // 字重不随已读 / 未读变化：粗细不同的字宽度不同，标题的换行会变，点一下行高就跟着跳。
                        // 已读 / 未读靠颜色、底色和圆点区分
                        .font(Theme.title(14, .medium, scheme: scheme))
                        // 未读：醒目的主色 + 加粗；已读：退成灰色，细字重
                        .foregroundStyle(unread ? Theme.text : Theme.muted)
                        .lineLimit(nil)   // 标题完整显示，太长就换行
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if thread.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Theme.faint) }
                }
                // PR 行不需要这一行（标题已经够认；仓库 / 编号 / 发件人点进去就能看到）；非 PR 的邮件靠发件人认
                // 正文概览：最近一封真人邮件的开头，扫一眼就知道说了什么
                if showSnippet || highlight != nil, !thread.preview.isEmpty {
                    Text(Highlight.text(thread.preview, query: highlight))
                        .font(Theme.ui(12))
                        .foregroundStyle(unread ? Theme.text.opacity(0.62) : Theme.faint)
                        .lineLimit(2)
                        .padding(.leading, 13)
                }
                // 底部一行：左边是 PR 号 / 评论数（或发件人），右边是这个 PR / 邮件最后一次更新的时间
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isPR { commentsLine(info) } else { metaLine(info) }
                    Spacer(minLength: 4)
                    Text(DateText.updated(thread.date))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                        .help("最后更新：" + DateText.full(thread.date))
                }
                .padding(.leading, 13)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, Theme.pad(compact ? 9 : 11))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(unread ? Theme.unreadFill : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.hover : .clear).allowsHitTesting(false) }
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Theme.accent).frame(width: 3).padding(.vertical, 8) }   // 选中只亮一条左侧竖线，不改背景
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        // VoiceOver：一行读成一句话（未读、标题、谁、内容开头、时间），而不是把每个小控件逐个读一遍
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary(title: title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func spokenSummary(title: String) -> String {
        var parts: [String] = []
        if thread.isUnread { parts.append(unread ? "未读" : "未读（仅例行消息）") }
        parts.append(title.isEmpty ? "无主题" : title)
        parts.append(actor)
        if !thread.preview.isEmpty { parts.append(thread.preview) }
        if thread.humanCount > 0 { parts.append("\(thread.humanCount) 条真人评论") }
        parts.append(DateText.updated(thread.date))
        return parts.joined(separator: "，")
    }

    /// 谁、在哪：发件人 · 仓库 #PR · Jira 编号。全是安静的灰色小字，不再是一堆药丸。
    private func metaLine(_ info: NotificationInfo?) -> some View {
        var parts: [String] = [actor]
        if let context = info?.context, info?.service == .github { parts.append(context) }
        if let reference = info?.reference { parts.append(reference.replacingOccurrences(of: "PR ", with: "")) }
        if info?.service == .github, let key = info?.jiraKey { parts.append(key) }
        return Text(parts.joined(separator: " · "))
            .font(Theme.mono(11, thread.humanUnread > 0 ? .medium : .regular))
            .foregroundStyle(thread.humanUnread > 0 ? Theme.muted : Theme.faint)
            .lineLimit(1).truncationMode(.middle)
    }
}

/// 列表里的日期分隔：吸顶的小标题 + 一条横线，后面是这一天有几个会话、几个未读。
private struct DayHeader: View {
    let title: String
    let count: Int
    let unread: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.ui(11.5, .semibold)).foregroundStyle(title == "今天" ? Theme.accent : Theme.muted)
            Text(unread > 0 ? "\(count) · \(unread) 未读" : "\(count)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, Theme.pad(10))
        .padding(.bottom, Theme.pad(6))
        .frame(maxWidth: .infinity)
        .background(Theme.bg)     // 吸顶时盖住下面滚过去的行，必须不透明
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread > 0 ? "\(title)，\(count) 个会话，\(unread) 个未读" : "\(title)，\(count) 个会话")
        .accessibilityAddTraits(.isHeader)
    }
}

/// 列表里的搜索高亮：命中的字加底色。
enum Highlight {
    static func text(_ string: String, query: String?) -> AttributedString {
        var text = AttributedString(string)
        guard let query else { return text }
        for range in SearchHighlight.ranges(of: query, in: string) {
            guard let start = AttributedString.Index(range.lowerBound, within: text),
                  let end = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[start..<end].backgroundColor = Color.yellow.opacity(0.4)
            text[start..<end].foregroundColor = Theme.text
        }
        return text
    }
}
