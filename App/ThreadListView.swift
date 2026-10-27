import MailCore
import SwiftUI

struct ThreadListView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService
    @AppStorage(Pref.loadOlderBatch) private var olderBatch = 50
    @AppStorage(Pref.listDensity) private var density = "compact"
    @AppStorage(Pref.showSnippets) private var showSnippets = true
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

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
                Text(title).font(Theme.ui(15, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(reader.threads.isEmpty ? "" : "\(reader.threads.count)\(reader.hasMore ? "+" : "")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                Spacer()
                groupToggle
                filterToggle
                Button { service.manualSync() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        .rotationEffect(.degrees(service.syncing ? 360 : 0))
                        .animation(service.syncing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: service.syncing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .pointerStyle(.link)
                .help("立即收取邮件（⌘R）")
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
                        .buttonStyle(.plain).foregroundStyle(Theme.faint)
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

    /// 来源分类标签：全部 / GitHub / Jira / 文档 / 其他，数字是有未读的分组数（没有未读就显示总数）。
    private var sourceTabs: some View {
        let counts = reader.sourceCounts
        let all = counts.values.reduce((groups: 0, unread: 0)) { ($0.groups + $1.groups, $0.unread + $1.unreadGroups) }
        return HStack(spacing: 4) {
            tab("全部", icon: nil, color: Theme.muted, source: nil, number: all.unread > 0 ? all.unread : all.groups, highlight: all.unread > 0)
            ForEach(ReaderModel.sourceOrder, id: \.self) { source in
                if let count = counts[source], count.groups > 0 {
                    let style = ReaderModel.style(forSource: source)
                    tab(style.title, icon: style.icon, color: Theme.color(named: style.color), source: source,
                        number: count.unreadGroups > 0 ? count.unreadGroups : count.groups, highlight: count.unreadGroups > 0)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tab(_ title: String, icon: String?, color: Color, source: String?, number: Int, highlight: Bool) -> some View {
        let active = reader.sourceFilter == source
        return Button { reader.sourceFilter = source } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9.5)).foregroundStyle(active ? color : Theme.faint) }
                Text(title).font(Theme.ui(11.5, active ? .semibold : .regular))
                Text("\(number)").font(Theme.mono(10)).foregroundStyle(highlight ? color : Theme.faint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .foregroundStyle(active ? Theme.text : Theme.muted)
            .background(active ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Color.clear : Theme.border.opacity(0.7), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    let rules = reader.rulesByName
                    let visible = reader.visibleThreads
                    ForEach(reader.sections) { section in
                        let collapsed = reader.isCollapsed(section)
                        Section {
                            if !collapsed {
                                ForEach(section.threads) { thread in
                                    ThreadRow(thread: thread, selected: thread.id == reader.selectedThreadID, rules: rules,
                                              viewingRule: { if case .rule(let name) = reader.mailbox { return name } else { return nil } }(),
                                              compact: density == "compact", showSnippet: showSnippets)
                                        .id(thread.id)
                                        .onTapGesture {
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
                            }
                        } header: {
                            SectionHeader(section: section, collapsed: collapsed, routineUnread: reader.stats.routineUnread,
                                          onToggle: { withAnimation(.easeInOut(duration: 0.12)) { reader.toggleSection(section) } },
                                          onClean: { reader.cleanRoutine() })
                        }
                    }
                    if !reader.threads.isEmpty, !reader.hasMore, reader.searchText.isEmpty { olderFooter }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(phases: .down) { handleKey($0) }
            .onChange(of: reader.selectedThreadID) { _, id in
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
                .buttonStyle(.plain)
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

// MARK: - Section header

private struct SectionHeader: View {
    let section: ReaderModel.ListSection
    let collapsed: Bool
    let routineUnread: Int
    let onToggle: () -> Void
    let onClean: () -> Void

    var body: some View {
        let color = Theme.color(named: section.colorName)
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(Theme.faint)
                    Image(systemName: section.icon).font(.system(size: 11)).foregroundStyle(color)
                    Text(section.title).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.text)
                    Text("\(section.threads.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    if section.unread > 0 { Text("· \(section.unread) 未读").font(Theme.mono(10.5)).foregroundStyle(color) }
            }
            Spacer()
            if section.cleanable, routineUnread > 0 {
                Button(action: onClean) {
                    Text("清理 \(routineUnread) 条例行未读").font(Theme.ui(11)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("把收件箱里所有未读的例行机器人邮件（质量门通过、包体积检查、测试汇总……）标为已读")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .contentShape(Rectangle())   // 整行都能点，不只是文字
        .onTapGesture(perform: onToggle)
        .pointerStyle(.link)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.8)).frame(height: 0.5) }
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
    @State private var hovering = false

    /// PR 分组用 PR 自己的最新一封 GitHub 邮件来识别标题和编号，不被最新一封是 Jira / 机器人带偏。
    private var info: NotificationInfo? {
        NotificationClassifier.classify(subject: thread.prSubject ?? thread.subject, from: thread.from,
                                        reason: Self.relation(thread.reasons) ?? thread.reason, body: thread.snippet)
    }

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

    /// 左侧色条：出问题红色，待处理橙色，否则取命中规则的颜色。
    private var barColor: Color {
        if thread.alertUnread > 0 { return Theme.red }
        if thread.needsAttention { return Theme.orange }
        return matched.first.map { Theme.color(for: $0) } ?? .clear
    }

    /// 谁最近动了：优先真人（最新一封往往是机器人）。
    private var actor: String {
        let from = isPR ? (thread.lastHumanFrom ?? thread.from) : thread.from
        return MailAddress.parse(from).displayName
    }

    var body: some View {
        let info = info
        let title = info?.title ?? thread.subject
        HStack(spacing: 0) {
            Rectangle().fill(barColor).frame(width: 3)
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                HStack(spacing: 6) {
                    // 未读圆点：有真人 / 出问题的未读是蓝点；只有例行机器人未读是灰点
                    Circle()
                        .fill(thread.isUnread ? (thread.onlyRoutineUnread && isPR ? Theme.faint : Theme.accent) : .clear)
                        .frame(width: 7, height: 7)
                    Text(actor)
                        .font(Theme.mono(12, thread.humanUnread > 0 || (!isPR && thread.isUnread) ? .semibold : .regular))
                        .foregroundStyle(thread.isUnread ? Theme.text : Theme.muted)
                        .lineLimit(1)
                    if let context = info?.context, info?.service == .github {
                        Text(context).font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 4)
                    if thread.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Theme.faint) }
                    Text(DateText.list(thread.date)).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                }
                Text(title.isEmpty ? "（无主题）" : title)
                    .font(Theme.ui(13, thread.humanUnread > 0 || thread.alertUnread > 0 || (!isPR && thread.isUnread) ? .semibold : .regular))
                    .foregroundStyle(thread.isUnread && !(thread.onlyRoutineUnread && isPR) ? Theme.text : Theme.text.opacity(0.7))
                    .lineLimit(compact ? 1 : 2)
                    .padding(.leading, 13)
                tagLine(info).padding(.leading, 13)
                if isPR { activityLine.padding(.leading, 13) }
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, compact ? 7 : 10)
        }
        .background(selected ? Theme.selection : (hovering ? Theme.hover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// PR 的活动摘要：几条新评论、几次失败、几条例行消息、Jira 联动——一眼看出这个 PR 的"热度"来自哪里。
    private var activityLine: some View {
        HStack(spacing: 8) {
            if thread.humanUnread > 0 {
                Label("\(thread.humanUnread) 条新评论", systemImage: "person.fill").foregroundStyle(Theme.accent)
            } else if thread.humanCount > 0 {
                Label("\(thread.humanCount) 条评论", systemImage: "person").foregroundStyle(Theme.muted)
            }
            if thread.alertCount > 0 {
                Label("\(thread.alertUnread > 0 ? thread.alertUnread : thread.alertCount) 次失败", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.red)
            }
            if thread.routineCount > 0 {
                Label("例行 \(thread.routineCount)", systemImage: "gearshape").foregroundStyle(Theme.faint)
            }
            if thread.jiraCount > 0 {
                Label("Jira \(thread.jiraCount)", systemImage: "checklist").foregroundStyle(Theme.color(for: .jira))
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(Theme.mono(10.5))
    }

    @ViewBuilder
    private func tagLine(_ info: NotificationInfo?) -> some View {
        let serviceColor = info.map { Theme.color(for: $0.service) } ?? Theme.muted
        let relationReason = Self.relation(thread.reasons)
        // 规则已经表达了这层关系（比如规则"请求你 Review"按 review_requested 匹配）就不再重复显示关系标签
        let coveredByRule = relationReason.map { reason in matched.contains { $0.reasons.contains(reason) } } ?? false
        let shownRules = matched.filter { $0.name != viewingRule }
        let relation = coveredByRule ? nil : relationReason.flatMap(GitHubReason.event(for:)).flatMap { $0.notable ? $0 : nil }
        let hasTags = !shownRules.isEmpty || info?.reference != nil || relation != nil || (!isPR && info?.event != nil)
        if hasTags {
            FlowLayout(spacing: 4, lineSpacing: 3) {
                if let relation { Chip(text: relation.label, color: Theme.color(named: relation.color), mono: false) }
                ForEach(shownRules.prefix(3), id: \.name) { rule in
                    if rule.name != relation?.label {
                        Chip(text: rule.name, color: Theme.color(for: rule), filled: Theme.priority(of: rule) == 3, mono: false)
                    }
                }
                if shownRules.count > 3 { Chip(text: "+\(shownRules.count - 3)", color: Theme.muted) }
                if let reference = info?.reference { Chip(text: reference, color: serviceColor) }
                if info?.service == .github, let key = info?.jiraKey { Chip(text: key, color: Theme.color(for: .jira)) }
                if !isPR, let event = info?.event { Chip(text: event.label, color: Theme.color(named: event.color), mono: false) }
            }
        } else if showSnippet, !thread.snippet.isEmpty, !isPR {
            Text(thread.snippet).font(Theme.ui(12)).foregroundStyle(Theme.faint).lineLimit(1)
        }
    }
}

/// 图标和文字挨得更紧的标签样式。
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}
