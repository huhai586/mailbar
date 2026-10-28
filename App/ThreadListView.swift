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
                .buttonStyle(PlainPointerButtonStyle())
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
                if let icon { IconImage(name: icon, size: 9.5).foregroundStyle(active ? color : Theme.faint) }
                Text(title).font(Theme.ui(11.5, active ? .semibold : .regular))
                Text("\(number)").font(Theme.mono(10)).foregroundStyle(highlight ? color : Theme.faint)
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

    /// 行的标识里带上会变的状态：已读 / 未读变了就换一个新的行视图。
    /// 只用 thread.id 时，LazyVStack 在「行换了位置、内容同时变了」时会继续显示旧内容（标成已读后那一行还是未读的样子）。
    static func rowKey(_ t: ThreadSummary) -> String {
        "\(t.id)|\(t.unreadCount)|\(t.humanUnread)|\(t.alertUnread)|\(t.routineUnread)"
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let rules = reader.rulesByName
                    let visible = reader.visibleThreads
                    ForEach(reader.threads) { thread in
                        // 外层按 thread.id 认行（滚动定位用），里层按状态认：已读 / 未读一变就换新的行视图，
                        // 不然 LazyVStack 在「行的位置和内容同时变」时会继续显示旧内容
                        VStack(spacing: 0) {
                            ThreadRow(thread: thread, selected: thread.id == reader.selectedThreadID, rules: rules,
                                      viewingRule: { if case .rule(let name) = reader.mailbox { return name } else { return nil } }(),
                                      compact: density != "spacious", showSnippet: showSnippets)
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
                    if !reader.threads.isEmpty, !reader.hasMore, reader.searchText.isEmpty { olderFooter }
                }
                .scrollTargetLayout()
            }
            // 新邮件到了不打乱正在看的位置：停在最顶上时跟着显示最新的；往下翻着时，眼前这一行保持不动
            .scrollPosition(id: $topRowID, anchor: .top)
            .onChange(of: reader.threads.map(\.id)) { old, new in
                if topRowID == nil || topRowID == old.first { topRowID = new.first }
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
        if thread.needsAttention { return Theme.accent }
        return .clear
    }

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
                        Image(systemName: thread.humanUnread > 0 ? "text.bubble.fill" : "text.bubble").font(.system(size: 10))
                        Text(thread.humanUnread > 0 ? "\(thread.humanCount) 条真人评论 · \(thread.humanUnread) 条新" : "\(thread.humanCount) 条真人评论")
                    }
                    .foregroundStyle(thread.humanUnread > 0 ? Theme.accent : Theme.muted)
                    .fontWeight(thread.humanUnread > 0 ? .medium : .regular)
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
            Rectangle().fill(barColor).frame(width: 3)
            ServiceIcon(source: thread.source, size: 15, color: unread ? Theme.accent : Theme.faint)
                .frame(width: 28, height: 28)
                .background(unread ? Theme.accent.opacity(0.14) : Theme.raised.opacity(0.5), in: Circle())
                .padding(.leading, 12)
                .padding(.top, Theme.pad(compact ? 9 : 11))   // 和右边文字块同样的上边距：图标顶端对齐标题顶端
            VStack(alignment: .leading, spacing: Theme.pad(compact ? 3 : 5)) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // 未读圆点：有真人 / 出问题的未读是强调色；只有例行机器人未读是灰点
                    Circle()
                        .fill(thread.isUnread ? (unread ? Theme.accent : Theme.faint) : .clear)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    Text(title.isEmpty ? "（无主题）" : title)
                        .font(Theme.title(14, unread ? .semibold : .regular, scheme: scheme))
                        // 未读：醒目的主色 + 加粗；已读：退成灰色，细字重
                        .foregroundStyle(unread ? Theme.text : Theme.muted)
                        .lineLimit(nil)   // 标题完整显示，太长就换行
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if thread.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Theme.faint) }
                }
                // PR 行不需要这一行（标题已经够认；仓库 / 编号 / 发件人点进去就能看到）；非 PR 的邮件靠发件人认
                if !isPR { metaLine(info).padding(.leading, 13) }
                if isPR { commentsLine(info).padding(.leading, 13) }
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, Theme.pad(compact ? 9 : 11))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(hovering ? Theme.hover : (unread ? Theme.raised.opacity(0.55) : .clear), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Theme.accent).frame(width: 3).padding(.vertical, 8) }   // 选中只亮一条左侧竖线，不改背景
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
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
