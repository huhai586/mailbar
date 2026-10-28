import AppKit
import MailCore
import SwiftUI

/// 右侧：选中会话 → 对话时间线；没选 → 今日概览。
struct ThreadDetailView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService

    var body: some View {
        Group {
            if reader.selectedThreadID != nil, !reader.messages.isEmpty {
                ThreadConversation(reader: reader, service: service)
                    .id(reader.selectedThreadID)   // 换会话时重置展开状态
            } else if reader.selectedThreadID != nil {
                Color.clear
            } else {
                DashboardView(reader: reader, service: service)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Conversation

private struct ThreadConversation: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService
    @State private var expanded: Set<String> = []
    @State private var showAllOlder = false
    @State private var didInitExpansion = false
    /// 下一次点"被 @ 提及"要跳到第几处；scrollRequest 的 nonce 保证连续跳同一封也会触发滚动
    @Environment(\.colorScheme) private var scheme
    @State private var mentionCursor = 0
    @State private var scrollRequest: (id: String, nonce: Int)?
    @State private var flashID: String?
    /// 打开会话时要定位到的那封（最早的未读）；没有未读就用第一封展开的
    @State private var focusTarget: String?
    /// 搜索：每封邮件有几处命中（卡片自己算好报上来），当前跳到第几处
    @State private var hitCounts: [String: Int] = [:]
    @State private var hitCursor = 0
    @State private var hitScroll: (anchor: String, nonce: Int)?

    private var query: String? { reader.highlightQuery }

    /// 主题、正文（原文或 HTML）里含搜索词的邮件。
    private var searchMatches: Set<String> {
        guard let query else { return [] }
        return Set(messages.filter { m in
            SearchHighlight.contains(query, in: m.subject) || SearchHighlight.contains(query, in: MessageText.of(m).plain)
                || (m.bodyHtml.map { SearchHighlight.contains(query, in: $0) } ?? false)
        }.map(\.id))
    }

    /// 所有命中，按时间线顺序：(邮件, 这封里的第几处)。
    private var hits: [(id: String, index: Int)] {
        shownMessages.flatMap { m in (0..<(hitCounts[m.id] ?? 0)).map { (m.id, $0) } }
    }

    private var messages: [MessageDetail] { reader.messages }
    private var filter: DetailFilter { reader.detailFilters[reader.selectedThreadID ?? ""] ?? DetailFilter() }
    private var shownMessages: [MessageDetail] { messages.filter { filter.includes($0.messageKind) } }
    private var humanMessages: [MessageDetail] { messages.filter { $0.messageKind == .human } }
    private var autoMessages: [MessageDetail] { messages.filter { $0.messageKind != .human } }
    /// 真人和自动化都有才需要筛选
    private var showsFilterBar: Bool { !humanMessages.isEmpty && !autoMessages.isEmpty }
    private func setFilter(_ f: DetailFilter) { if let id = reader.selectedThreadID { reader.detailFilters[id] = f } }
    private var subject: String { messages.last?.subject ?? "" }
    private var info: NotificationInfo? { reader.primaryInfo }
    /// 侧栏正在看的规则：每封都命中它，头部不用再重复显示
    private var viewingRule: String? { if case .rule(let name) = reader.mailbox { return name } else { return nil } }
    private var matchedRules: [Rule] {
        let names = Set(reader.selectedThread?.ruleNames ?? [])
        return service.rules.filter { names.contains($0.name) }
            .sorted { Theme.priority(of: $0) > Theme.priority(of: $1) }
    }

    private enum Item: Identifiable {
        case message(MessageDetail)
        /// 一串连续的例行机器人消息，折成一行
        case routine([MessageDetail])
        /// 长时间线中间被折叠的部分（数字是被折叠的邮件数）
        case folded(Int)

        var id: String {
            switch self {
            case .message(let m): return m.id
            case .routine(let run): return "routine-\(run[0].id)"
            case .folded: return "folded"
            }
        }

        var messageCount: Int {
            switch self {
            case .message: return 1
            case .routine(let run): return run.count
            case .folded(let count): return count
            }
        }
    }

    /// 先把连续的例行机器人消息折成一项（一个 PR 里往往有几十条"质量门通过"、"包体积没变"），
    /// 再对仍然很长的时间线折叠中间：保留第一项和最后 8 项。
    private var items: [Item] {
        var base: [Item] = []
        var run: [MessageDetail] = []
        func flush() {
            if !run.isEmpty { base.append(.routine(run)) }
            run = []
        }
        // 只看某一类时不折叠，逐条列出
        // 整个会话都是例行机器人消息（比如单独一封 SonarQube 通知）时也不折叠：折成一行就没有详情可看了
        let fold = filter.tab == .all && shownMessages.contains { $0.messageKind != .botRoutine }
        for message in shownMessages {
            // 打开时还没读的、搜索命中的例行消息不折叠：点进来就是为了看它
            if fold, message.messageKind == .botRoutine, !reader.openedUnreadIDs.contains(message.id), !searchMatches.contains(message.id) {
                run.append(message)
            } else {
                flush()
                base.append(.message(message))
            }
        }
        flush()
        // 搜索时不折叠中间：命中可能就在中间
        guard base.count > 12, !showAllOlder, searchMatches.isEmpty else { return base }
        let hidden = base[1..<(base.count - 8)]
        return [base[0], .folded(hidden.reduce(0) { $0 + $1.messageCount })] + base.suffix(8)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !service.canModify, Pref.markRead != .manual { authorizeBanner }
            header
            if showsFilterBar { filterBar }
            if let query, !hits.isEmpty { searchBar(query) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Theme.pad(10)) {
                        if let key = reader.selectedThreadID {
                            AISummaryCard(reader: reader, groupKey: key, messages: messages, title: subject)
                        }
                        if shownMessages.isEmpty {
                            Text("这一类里没有邮件").font(Theme.ui(12.5)).foregroundStyle(Theme.faint).padding(.top, 40)
                        }
                        ForEach(items) { item in
                            switch item {
                            case .message(let message):
                                MessageCard(message: message, info: reader.info(for: message),
                                            onSetKind: { service.setKind(forSender: MailAddress.parse(message.from).address, $0) },
                                            githubLogin: reader.githubLogin,
                                            expanded: binding(message.id),
                                            highlight: query,
                                            currentHit: currentHit(in: message.id),
                                            onHitCount: { hitCounts[message.id] = $0 })
                                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.accent, lineWidth: 1.5).opacity(flashID == message.id ? 1 : 0))
                                    .id(message.id)
                            case .routine(let run):
                                RoutineRunRow(messages: run, info: { reader.info(for: $0) })
                            case .folded(let count):
                                Button { withAnimation(.easeInOut(duration: 0.15)) { showAllOlder = true } } label: {
                                    Label("展开中间折叠的 \(count) 封邮件", systemImage: "ellipsis")
                                        .font(Theme.mono(11.5)).foregroundStyle(Theme.accent)
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
                                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                }
                                .buttonStyle(PlainPointerButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 20)
                    .padding(.vertical, Theme.pad(16))
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: scrollRequest?.nonce) {
                    guard let id = scrollRequest?.id else { return }
                    // 等展开 / 切换 tab 之后的布局完成再滚
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                .onChange(of: hitScroll?.nonce) {
                    guard let anchor = hitScroll?.anchor, let id = hits[safe: hitCursor]?.id else { return }
                    // 先滚到那封邮件；正文是网页的，加载完量出命中位置后再对准那一处
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(id, anchor: .top) }
                    for delay in [0.35, 0.9] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .top) }
                        }
                    }
                }
                // 在详情里改了搜索词：展开新命中的邮件，从第一处开始
                .onChange(of: query) {
                    hitCursor = 0
                    expanded.formUnion(searchMatches)
                    if !searchMatches.isEmpty { DispatchQueue.main.async { jumpToHit(0) } }
                }
                .onAppear { focusInitial(proxy) }
                // 切换会话时 messages 可能比视图晚一拍更新：这时展开集合里全是上一个会话的邮件 id，一封都对不上，要重新来一遍
                .onChange(of: messages.map(\.id)) {
                    if expanded.isDisjoint(with: Set(messages.map(\.id))) {
                        didInitExpansion = false
                        focusInitial(proxy)
                    }
                }
            }
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        let humanUnread = humanMessages.filter(\.isUnread).count
        let autoUnread = autoMessages.filter(\.isUnread).count
        let alertUnread = autoMessages.filter { $0.messageKind == .botAlert && $0.isUnread }.count
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                filterTab("全部", count: messages.filter(\.isUnread).count, active: filter.tab == .all) { setFilter(DetailFilter()) }
                filterTab("真人", count: humanUnread, active: filter.tab == .human) { setFilter(DetailFilter(tab: .human)) }
                filterTab("自动化", count: alertUnread > 0 ? alertUnread : autoUnread, alert: alertUnread > 0, active: filter.tab == .auto) {
                    setFilter(DetailFilter(tab: .auto, sub: filter.tab == .auto ? filter.sub : .all))
                }
                if filter.tab == .auto {
                    Rectangle().fill(Theme.border).frame(width: 1, height: 14).padding(.horizontal, 4)
                    filterTab("全部", count: 0, active: filter.sub == .all, small: true) { setFilter(DetailFilter(tab: .auto, sub: .all)) }
                    filterTab("失败", count: alertUnread, alert: true, active: filter.sub == .alert, small: true) { setFilter(DetailFilter(tab: .auto, sub: .alert)) }
                    if autoMessages.contains(where: { $0.messageKind == .push }) {
                        filterTab("推送", count: autoMessages.filter { $0.messageKind == .push && $0.isUnread }.count, active: filter.sub == .push, small: true) { setFilter(DetailFilter(tab: .auto, sub: .push)) }
                    }
                    filterTab("例行", count: 0, active: filter.sub == .routine, small: true) { setFilter(DetailFilter(tab: .auto, sub: .routine)) }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            Divider().overlay(Theme.border)
        }
        .background(Theme.panel)
    }

    /// count 是未读数；alert 表示里面有出问题的，数字标红。
    private func filterTab(_ title: String, count: Int, alert: Bool = false, active: Bool, small: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(Theme.ui(small ? 11.5 : 12.5, active ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)").font(Theme.mono(10.5, .semibold))
                        .foregroundStyle(alert ? Theme.red : Theme.accent)
                }
            }
            .foregroundStyle(active ? Theme.text : Theme.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, Theme.pad(5))
            .overlay(alignment: .bottom) { if active { Rectangle().fill(Theme.accent).frame(height: 2).padding(.horizontal, 4) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPointerButtonStyle())
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func focusInitial(_ proxy: ScrollViewProxy) {
        initExpansion()
        // 目标被"折叠中间 N 封"藏起来时先展开折叠，不然滚不到
        if let id = focusTarget, !items.contains(where: { if case .message(let m) = $0 { return m.id == id } else { return false } }) {
            showAllOlder = true
        }
        if let target = focusTarget ?? firstExpandedAfterFold() {
            // 上面的邮件正文（网页）加载完会长高，把目标往下推：等它们排好版再对准一次
            for delay in [0.05, 0.45, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }

    /// 默认展开最新一封非例行的邮件，以及最近几封未读的（例行消息折在一起，不算）。
    private func initExpansion() {
        guard !didInitExpansion else { return }
        didInitExpansion = true
        let nonRoutine = messages.filter { $0.messageKind != .botRoutine }
        let relevant = nonRoutine.isEmpty ? messages : nonRoutine
        var open: Set<String> = []
        if let last = relevant.last { open.insert(last.id) }
        // 从列表点进来是为了看新邮件：展开打开时还没读的（不管是真人还是机器人，最多 5 封），并滚到其中最早的一封
        let unread = Array(messages.filter { reader.openedUnreadIDs.contains($0.id) }.suffix(5))
        for message in unread { open.insert(message.id) }
        // 从搜索结果点进来：展开命中的邮件，定位到第一处命中（优先于未读）
        let matched = messages.filter { searchMatches.contains($0.id) }
        for message in matched.prefix(20) { open.insert(message.id) }
        expanded = open
        focusTarget = matched.first?.id ?? unread.first?.id
        // 之前在这个会话里选过「真人」之类的筛选，会把未读 / 命中的那封藏起来：先切回「全部」
        if (unread + matched).contains(where: { !filter.includes($0.messageKind) }) { setFilter(DetailFilter()) }
        if !matched.isEmpty { DispatchQueue.main.async { jumpToHit(0) } }
    }

    // MARK: Search hits

    private func currentHit(in messageId: String) -> Int? {
        guard let hit = hits[safe: hitCursor], hit.id == messageId else { return nil }
        return hit.index
    }

    /// 跳到第 n 处命中（循环）：展开那封邮件，滚过去，并把那一处标成「当前」。
    private func jumpToHit(_ n: Int) {
        let all = hits
        guard !all.isEmpty else { return }
        hitCursor = (n % all.count + all.count) % all.count
        let hit = all[hitCursor]
        expanded.insert(hit.id)
        hitScroll = ("hit-\(hit.id)-\(hit.index)", (hitScroll?.nonce ?? 0) + 1)
    }

    /// 搜索时显示在详情顶部：一共几处、当前第几处，上一处 / 下一处（⇧⌘G / ⌘G，或 ⇧↩ / ↩）。
    private func searchBar(_ query: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text("「\(query)」").font(Theme.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Text("\(min(hitCursor + 1, hits.count)) / \(hits.count)").font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
            Spacer()
            Button { jumpToHit(hitCursor - 1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 20) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("上一处（⇧⌘G）")
            Button { jumpToHit(hitCursor + 1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 20) }
                .keyboardShortcut("g", modifiers: .command)
                .help("下一处（⌘G）")
        }
        .buttonStyle(PlainPointerButtonStyle())
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    private func firstExpandedAfterFold() -> String? {
        items.compactMap { item -> String? in
            if case .message(let m) = item, expanded.contains(m.id) { return m.id }
            return nil
        }.first
    }

    // MARK: Header

    private var serviceColor: Color { info.map { Theme.color(for: $0.service) } ?? Theme.muted }

    private var header: some View {
        let link = reader.serviceLink()
        let ciFailures = reader.selectedThread?.ciFailures ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text((info?.title ?? subject).isEmpty ? "（无主题）" : (info?.title ?? subject))
                    .font(Theme.title(19, .semibold, scheme: scheme))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ActionButton(icon: reader.selectedThreadHasUnread ? "envelope.open" : "envelope.badge",
                                 title: reader.selectedThreadHasUnread ? "已读" : "未读", key: "m",
                                 help: reader.selectedThreadHasUnread ? "把整组邮件标为已读" : "把最新一封标为未读", enabled: service.canModify) {
                        if let id = reader.selectedThreadID { reader.toggleRead(threadId: id) }
                    }
                    if let link {
                        ActionButton(icon: link.icon, title: link.name, key: "g", help: "在 \(link.name) 中打开") { NSWorkspace.shared.open(link.url) }
                    }
                    ActionButton(icon: "arrow.up.right.square", title: "Gmail", key: "o", help: "在 Gmail 中打开（回复等）") {
                        NSWorkspace.shared.open(gmailURL(threadId: reader.selectedThread?.latestThreadId ?? messages.last?.threadId, account: service.accountEmail))
                    }
                }
            }
            FlowLayout(spacing: 5, lineSpacing: 4) {
                if let info {
                    let context = info.context ?? info.service.displayName
                    if info.service == .github, let context = info.context, let url = URL(string: "https://github.com/\(context)") {
                        LinkChip(text: context, url: url, icon: "github", help: "在 GitHub 中打开仓库 \(context)")
                    } else {
                        Chip(text: context, color: serviceColor, icon: ReaderModel.icon(for: info.service))
                    }
                    if let reference = info.reference {
                        if let link {
                            LinkChip(text: reference, url: link.url, help: "在 \(link.name) 中打开 \(reference)")
                        } else {
                            Chip(text: reference, color: serviceColor)
                        }
                    }
                    if info.service == .github, let key = info.jiraKey {
                        // PR 标题里的 Jira 编号：点一下跳到 Jira 工单
                        if let url = reader.jiraURL(forKey: key) {
                            LinkChip(text: key, url: url, icon: "jira", help: "在 Jira 中打开 \(key)")
                        } else {
                            Chip(text: key, color: Theme.color(for: .jira), icon: "checklist")
                        }
                    }
                }
                ForEach(matchedRules.filter { $0.name != viewingRule }, id: \.name) { rule in
                    if isMentionRule(rule), !mentionIDs.isEmpty {
                        mentionChip(rule.name, color: Theme.color(for: rule))
                    } else {
                        Chip(text: rule.name, color: Theme.color(for: rule), filled: Theme.priority(of: rule) == 3, mono: false)
                    }
                }
                if ciFailures > 0 { Chip(text: "CI 失败 ×\(ciFailures)", color: Theme.red, mono: false) }
                if matchedRules.isEmpty, let event = info?.event, ciFailures == 0 || event.label != "CI 失败" {
                    if ["提及你", "团队提及", "提到你"].contains(event.label), !mentionIDs.isEmpty {
                        mentionChip(event.label, color: Theme.color(named: event.color))
                    } else {
                        Chip(text: event.label, color: Theme.color(named: event.color), mono: false)
                    }
                }
            }
            Text(metaLine).font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.top, Theme.pad(16))
        .padding(.bottom, Theme.pad(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: 被 @ 提及

    /// 真正 @ 到你的邮件（按时间顺序）。机器人邮件里的"提及"不算，见 GitHubReason.describesThisMessage。
    private var mentionIDs: [String] {
        let mentioned = messages.filter { $0.reason == "mention" || $0.reason == "team_mention" }
        let exact = mentioned.filter {
            GitHubReason.describesThisMessage(reason: $0.reason, body: $0.bodyText, kind: $0.messageKind, login: reader.githubLogin)
        }
        // 正文里找不到 @你（比如团队提及、GitHub 的判断和用户名不一致）时，退而求其次：GitHub 标成提及的真人邮件
        let github = exact.isEmpty ? mentioned.filter { $0.messageKind == .human } : exact
        // Jira / 文档没有 X-GitHub-Reason：按每封邮件自己的识别结果（"X mentioned you"）找
        let events = messages.filter { reader.info(for: $0)?.event?.label == "提到你" }
        let named = reader.jiraName.map { name in events.filter { $0.bodyText.range(of: name, options: .caseInsensitive) != nil } } ?? []
        let others = named.isEmpty ? events : named
        let ids = Set(github.map(\.id) + others.map(\.id))
        return messages.map(\.id).filter(ids.contains)
    }

    private func isMentionRule(_ rule: Rule) -> Bool {
        rule.reasons.contains { $0.contains("mention") } || rule.name.contains("提到") || rule.name.contains("提及")
            || rule.keywords.contains { $0.lowercased().contains("mentioned you") }
    }

    private func mentionChip(_ title: String, color: Color) -> some View {
        let ids = mentionIDs
        let next = mentionCursor % ids.count
        return JumpChip(text: title, color: color, badge: ids.count > 1 ? "\(next + 1)/\(ids.count)" : nil,
                        help: ids.count > 1 ? "跳到第 \(next + 1) 处提及（共 \(ids.count) 处），再点跳到下一处" : "跳到提及你的那封邮件") {
            jumpToMention(ids[next])
            mentionCursor = next + 1
        }
    }

    private func jumpToMention(_ id: String) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        // 当前 tab 里看不到这封（比如在"自动化"）就回到"全部"
        if !filter.includes(message.messageKind) { setFilter(DetailFilter()) }
        showAllOlder = true
        expanded.insert(id)
        scrollRequest = (id, (scrollRequest?.nonce ?? 0) + 1)
        flashID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if flashID == id { flashID = nil } }
    }

    private var metaLine: String {
        var seen = Set<String>()
        let people = messages.map { MailAddress.parse($0.from).displayName }.filter { seen.insert($0).inserted }
        let shown = people.prefix(4).joined(separator: "、") + (people.count > 4 ? " 等 \(people.count) 人" : "")
        let threads = reader.selectedThread?.threadCount ?? 1
        var count = threads > 1 ? "\(messages.count) 封邮件，来自 \(threads) 个会话" : "\(messages.count) 封邮件"
        let kinds = Dictionary(grouping: messages, by: \.messageKind).mapValues(\.count)
        let parts = [kinds[.human].map { "真人 \($0)" }, kinds[.botAlert].map { "失败 \($0)" }, kinds[.push].map { "推送 \($0)" }, kinds[.botRoutine].map { "例行 \($0)" }].compactMap { $0 }
        if parts.count > 1 || kinds[.botRoutine] != nil { count += "（\(parts.joined(separator: " · "))）" }
        return "\(count) · \(shown) · 最近 \(DateText.full(messages.last?.date ?? Date()))"
    }

    private var authorizeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.yellow)
            Text("要在查看邮件后自动标为已读，需要升级授权（允许修改已读 / 未读状态）。").font(Theme.ui(12))
            Spacer()
            Button("授权…") { service.signIn() }.controlSize(.small)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 6)
        .background(Theme.yellow.opacity(0.14))
    }
}

/// 一串连续的例行机器人消息：折成一行，点开才看。
private struct RoutineRunRow: View {
    let messages: [MessageDetail]
    let info: (MessageDetail) -> NotificationInfo?
    @State private var open = false
    @State private var expandedIds: Set<String> = []

    private var summary: String {
        var counts: [String: Int] = [:]
        for message in messages { counts[MessageClassifier.routineLabel(subject: message.subject, body: message.bodyText), default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) ×\($0.value)" }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.12)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    Text("例行机器人消息 ×\(messages.count)").font(Theme.ui(12, .medium)).foregroundStyle(Theme.muted)
                    Text(summary).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    if messages.contains(where: \.isUnread) { Circle().fill(Theme.faint).frame(width: 6, height: 6) }
                    Spacer(minLength: 4)
                    Text(DateText.list(messages.last?.date ?? Date())).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPointerButtonStyle())
            if open {
                ForEach(messages) { message in
                    MessageCard(message: message, info: info(message),
                                expanded: Binding(get: { expandedIds.contains(message.id) },
                                                  set: { if $0 { expandedIds.insert(message.id) } else { expandedIds.remove(message.id) } }))
                }
            }
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let title: String
    var key: String?
    var help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                IconImage(name: icon, size: 10.5)
                Text(title).font(Theme.ui(11.5, .medium))
                if let key { Text(key).font(Theme.mono(9.5)).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(enabled ? Theme.text : Theme.faint)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(PlainPointerButtonStyle())
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Message card

/// 渲染 Markdown 的结果缓存：同一封邮件反复展开 / 切换时不重复解析。
private final class MarkdownCache: @unchecked Sendable {
    static let shared = MarkdownCache()
    private let cache = NSCache<NSString, NSString>()

    func html(for markdown: String) -> String {
        let key = "\(markdown.count)-\(markdown.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let rendered = MarkdownRenderer.html(from: markdown)
        cache.setObject(rendered as NSString, forKey: key)
        return rendered
    }
}

/// 正文的显示方式：Markdown 渲染 / 原文 / 邮件自带的 HTML。
private enum BodyMode {
    case markdown, text, html

    var label: String {
        switch self {
        case .markdown: return "MD"
        case .text: return "原文"
        case .html: return "HTML"
        }
    }
}

private struct MessageCard: View {
    let message: MessageDetail
    let info: NotificationInfo?
    var onSetKind: ((MessageKind) -> Void)?
    var githubLogin: String?
    @Binding var expanded: Bool
    /// 搜索词：正文里高亮它
    var highlight: String?
    /// 当前跳到的是这封邮件里的第几处
    var currentHit: Int?
    /// 这封邮件按当前显示方式有几处命中（外面用来在各处之间跳转）
    var onHitCount: ((Int) -> Void)?
    @State private var hitOffsets: [CGFloat] = []
    @Environment(\.colorScheme) private var scheme
    @AppStorage(Pref.githubTextView) private var githubText = true
    @AppStorage(Pref.renderMarkdown) private var renderMarkdown = true
    @AppStorage(Pref.invertEmails) private var invertEmails = true
    @AppStorage(Pref.monoBody) private var monoBody = true
    @State private var forcedMode: BodyMode?
    @State private var allowRemote = Pref.remoteImagesDefault
    @State private var htmlHeight: CGFloat = 160

    private var sender: MailAddress { MailAddress.parse(message.from) }

    /// 正文的各种整理结果（去页脚、CI 摘要、是否像 Markdown……）每封邮件只算一次。
    private var text: MessageText { MessageText.of(message) }
    private var plainText: String { text.plain }
    /// GitHub 通知的页脚（"You are receiving this because you were mentioned."）：正文里不放，单独以小字显示在卡片底部。
    private var footerNote: String? { text.footer }
    /// CI 失败通知：几十行任务清单只留失败的，按原文显示。
    private var digest: String? { text.digest }

    private var availableModes: [BodyMode] {
        var modes: [BodyMode] = []
        if renderMarkdown, digest == nil, !plainText.isEmpty { modes.append(.markdown) }
        if !plainText.isEmpty { modes.append(.text) }
        if message.bodyHtml != nil { modes.append(.html) }
        return modes
    }

    /// 默认显示方式：CI 摘要看原文；GitHub 评论本身就是 Markdown；有 HTML 的邮件看 HTML；纯文本邮件看起来像 Markdown 就渲染。
    private var defaultMode: BodyMode {
        if digest != nil { return .text }
        if message.isGitHubNotification, githubText, !plainText.isEmpty { return renderMarkdown ? .markdown : .text }
        if message.bodyHtml != nil { return .html }
        if renderMarkdown, text.looksLikeMarkdown { return .markdown }
        return .text
    }

    private var mode: BodyMode {
        if let forcedMode, availableModes.contains(forcedMode) { return forcedMode }
        return availableModes.contains(defaultMode) ? defaultMode : (availableModes.first ?? .text)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if expanded {
                Rectangle().fill(Theme.border).frame(height: 0.5)
                content
                if let note = footerNote {
                    Text(note)
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 0.5) }
                }
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(message.isUnread ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { onHitCount?(hitCount) }
        .onChange(of: "\(highlight ?? "")|\(mode)") { onHitCount?(hitCount) }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Avatar(name: sender.displayName, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(sender.displayName).font(Theme.mono(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if message.isUnread { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                    // PR 时间线里混着评论、CI 结果、Jira 联动：给非评论的邮件标上来源和事件
                    if let info {
                        if info.service != .github {
                            Chip(text: info.reference ?? info.service.displayName, color: Theme.color(for: info.service), icon: ReaderModel.icon(for: info.service))
                        }
                        if let event = info.event, event.notable || info.service != .github,
                           GitHubReason.describesThisMessage(reason: message.reason, body: message.bodyText, kind: message.messageKind, login: githubLogin) {
                            Chip(text: event.label, color: Theme.color(named: event.color), mono: false)
                        }
                        if let workflow = info.detail { Chip(text: workflow, color: Theme.muted) }
                    }
                }
                if !expanded {
                    Text(previewLine).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
                } else if sender.name != nil {
                    Text(sender.address).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if message.hasAttachments { Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(Theme.faint) }
            if expanded, onSetKind != nil { kindMenu }
            if expanded, availableModes.count > 1 { formatToggle }
            Text(DateText.list(message.date)).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                .help(DateText.full(message.date))
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.pad(expanded ? 9 : 7))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } }
        .pointerStyle(.link)
    }

    private static let kindChoices: [(MessageKind, String)] = [
        (.human, "真人"), (.botRoutine, "例行机器人"), (.botAlert, "出问题的机器人"), (.bot, "其他机器人"), (.push, "推送"),
    ]

    /// 识别错了：把这个发件人一律归为所选类型（在 设置 → 识别 里能看到、修改、撤销）。
    private var kindMenu: some View {
        Menu {
            Section("把「\(sender.displayName)」的邮件一律归为") {
                ForEach(Self.kindChoices, id: \.0) { choice in
                    Button { onSetKind?(choice.0) } label: {
                        if message.messageKind == choice.0 { Label(choice.1, systemImage: "checkmark") } else { Text(choice.1) }
                    }
                }
            }
        } label: {
            Label(Self.kindChoices.first { $0.0 == message.messageKind }?.1 ?? "归类", systemImage: "person.badge.shield.checkmark")
                .font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("识别错了？点这里改这个发件人的类型")
    }

    /// 折叠时的一行预览：去掉行首的 Markdown 标记。
    private var previewLine: String { text.preview }

    /// 在可用的显示方式之间循环：MD → 原文 → HTML。
    private var formatToggle: some View {
        Button {
            let modes = availableModes
            if let index = modes.firstIndex(of: mode) { forcedMode = modes[(index + 1) % modes.count] }
        } label: {
            Text(mode.label)
                .font(Theme.mono(10, .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .foregroundStyle(Theme.muted)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(PlainPointerButtonStyle())
        .help("切换显示方式（" + availableModes.map(\.label).joined(separator: " / ") + "）")
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .html:
            if let html = message.bodyHtml { webContent(marked(html), style: .email, dark: scheme == .dark && invertEmails) }
        case .markdown:
            webContent(marked(MarkdownCache.shared.html(for: plainText)), style: .markdown, dark: scheme == .dark)
        case .text:
            Text(highlightedText.text)
                .font(monoBody ? Theme.mono(12.5) : Theme.ui(13.5))
                .lineSpacing(monoBody ? 3 : 4)
                .foregroundStyle(Theme.text)
                .tint(Theme.accent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .overlay(alignment: .top) { hitAnchors(offsets: Array(repeating: 0, count: hitCount)) }
        }
    }

    // MARK: 搜索高亮

    private func marked(_ html: String) -> String {
        guard let highlight else { return html }
        return HitCache.marked(html, query: highlight).html
    }

    /// 原文显示时的高亮：命中处加底色，当前这一处更醒目。
    private var highlightedText: (text: AttributedString, count: Int) {
        var text = RichText.make(digest ?? plainText)
        guard let highlight else { return (text, 0) }
        let plain = String(text.characters)
        let ranges = SearchHighlight.ranges(of: highlight, in: plain)
        for (index, range) in ranges.enumerated() {
            guard let start = AttributedString.Index(range.lowerBound, within: text),
                  let end = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[start..<end].backgroundColor = index == currentHit ? Color(red: 1, green: 0.59, blue: 0.2) : Color.yellow.opacity(0.45)
            if index == currentHit { text[start..<end].foregroundColor = .black }
        }
        return (text, ranges.count)
    }

    /// 按当前显示方式，这封邮件有几处命中（折叠着也要算，外面才能跳过来）。
    private var hitCount: Int {
        guard let highlight else { return 0 }
        switch mode {
        case .html: return message.bodyHtml.map { HitCache.marked($0, query: highlight).count } ?? 0
        case .markdown: return HitCache.marked(MarkdownCache.shared.html(for: plainText), query: highlight).count
        case .text: return highlightedText.count
        }
    }

    /// 每处命中放一个看不见的锚点，外面 scrollTo("hit-邮件id-序号") 就能对准它。
    private func hitAnchors(offsets: [CGFloat]) -> some View {
        ZStack(alignment: .top) {
            ForEach(Array(offsets.enumerated()), id: \.offset) { index, y in
                Color.clear.frame(height: 1).padding(.top, max(0, y - 60)).id("hit-\(message.id)-\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func webContent(_ html: String, style: HTMLBodyView.Style, dark: Bool) -> some View {
        VStack(spacing: 0) {
            if !allowRemote, HTMLBodyView.hasRemoteImages(html) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(Theme.muted)
                    Text("已阻止远程图片").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    Button("加载") { allowRemote = true }.controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.raised)
            }
            HTMLBodyView(html: html, allowRemoteImages: allowRemote, dark: dark, style: style, height: $htmlHeight,
                         currentHit: currentHit, onHitOffsets: highlight == nil ? nil : { hitOffsets = $0 })
                .frame(height: htmlHeight)
                .overlay(alignment: .top) { hitAnchors(offsets: hitOffsets) }
                .onAppear {
                    if let cached = HTMLBodyView.heightCache[HTMLBodyView.heightKey(html: html, dark: dark, style: style)] { htmlHeight = cached }
                }
        }
    }
}

/// 一封邮件正文的整理结果。卡片每次重绘都要用好几次，按邮件缓存，只算一次。
struct MessageText {
    let plain: String
    let footer: String?
    let digest: String?
    let preview: String
    let looksLikeMarkdown: Bool

    @MainActor private static var cache: [String: MessageText] = [:]

    @MainActor static func of(_ message: MessageDetail) -> MessageText {
        let key = "\(message.id)|\(message.bodyText.count)"
        if let hit = cache[key] { return hit }
        if cache.count > 2_000 { cache.removeAll() }
        let raw = message.bodyText.isEmpty ? message.snippet : message.bodyText
        let plain = message.isGitHubNotification ? GitHubText.stripFooter(raw) : raw
        let digest = message.isGitHubNotification ? GitHubText.ciDigest(plain) : nil
        let made = MessageText(plain: plain,
                               footer: message.isGitHubNotification ? GitHubText.footerNote(raw) : nil,
                               digest: digest,
                               preview: previewLine(digest ?? plain, fallback: message.snippet),
                               looksLikeMarkdown: MarkdownRenderer.looksLikeMarkdown(plain))
        cache[key] = made
        return made
    }

    /// GitHub 评论邮件的第一行总是 "xxx left a comment (owner/repo#123)"，没有信息量，预览取后面的内容；去掉行首的 Markdown 标记。
    static func previewLine(_ source: String, fallback: String) -> String {
        let line = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.contains(" left a comment (") && !$0.hasPrefix("<!--") } ?? fallback
        let cleaned = line.drop { "#>*-|` ".contains($0) }.replacingOccurrences(of: "**", with: "")
        return String(cleaned.prefix(160))
    }
}

/// 给网页正文打高亮标记的结果，按「内容 + 搜索词」缓存：卡片每次重绘都要用。
@MainActor
enum HitCache {
    private static var cache: [String: (html: String, count: Int)] = [:]

    static func marked(_ html: String, query: String) -> (html: String, count: Int) {
        let key = "\(query)|\(html.count)|\(html.hashValue)"
        if let hit = cache[key] { return hit }
        if cache.count > 400 { cache.removeAll() }
        let result = SearchHighlight.markHTML(html, query: query)
        cache[key] = result
        return result
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
