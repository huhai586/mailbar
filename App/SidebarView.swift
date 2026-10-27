import AppKit
import MailCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService

    @AppStorage(Pref.sidebarShown) private var shownRaw = "UNREAD,ALL"
    private var shown: Set<String> { Pref.parseShown(shownRaw) }
    private var userLabels: [LabelInfo] { reader.labels.filter { $0.type == "user" && shown.contains($0.id) } }
    private var categories: [LabelInfo] {
        reader.labels.filter { SystemMailbox.categoryNames[$0.id] != nil && $0.messageCount > 0 && shown.contains($0.id) }
    }
    private var mailboxes: [SystemMailbox] { SystemMailbox.all.filter { shown.contains($0.key) } }
    private var enabledRules: [Rule] { service.rules.filter(\.enabled) }
    private func ruleCount(_ name: String) -> Int { reader.ruleCounts.first { $0.name == name }?.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            brand
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.pad(14)) {
                    section("分诊") {
                        row(icon: "exclamationmark.bubble.fill", iconColor: Theme.accent, title: "待处理", mailbox: .attention,
                            badge: reader.stats.attention, badgeColor: Theme.accent)
                        row(icon: "bolt.fill", iconColor: Theme.muted, title: "重点", mailbox: .important,
                            badge: reader.stats.importantUnread, badgeColor: Theme.accent)
                    }
                    section("来源") {
                        ForEach(ReaderModel.sourceOrder, id: \.self) { source in
                            if let count = reader.inboxSourceCounts[source], count.groups > 0 { sourceRow(source, count) }
                        }
                    }
                    section("规则", action: ("slider.horizontal.3", "管理规则", { service.openSettings?("rules") })) {
                        ForEach(enabledRules, id: \.name) { rule in
                            ruleRow(rule)
                        }
                        if enabledRules.isEmpty {
                            Button { service.addRecommendedRules() } label: {
                                Label("添加推荐规则（GitHub / Jira）", systemImage: "wand.and.stars")
                                    .font(Theme.ui(12))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }
                    if !mailboxes.isEmpty {
                        section("邮箱", action: ("eye", "选择显示哪些邮箱和标签", { service.openSettings?("general") })) {
                            ForEach(mailboxes) { item in
                                row(icon: item.icon, iconColor: Theme.muted, title: item.title, mailbox: item.mailbox,
                                    badge: item.mailbox == .label("INBOX") ? reader.stats.inboxUnread
                                        : item.mailbox == .unread ? reader.stats.inboxUnread : 0, badgeColor: Theme.accent)
                            }
                        }
                    }
                    if !categories.isEmpty {
                        section("分类") {
                            ForEach(categories) { label in
                                row(icon: "square.stack", iconColor: Theme.muted, title: SystemMailbox.categoryNames[label.id] ?? label.name,
                                    mailbox: .label(label.id), badge: label.unreadCount, badgeColor: Theme.muted)
                            }
                        }
                    }
                    if !userLabels.isEmpty {
                        section("标签") {
                            ForEach(userLabels) { label in
                                row(icon: "tag", iconColor: Theme.muted, title: label.name, mailbox: .label(label.id),
                                    badge: label.unreadCount, badgeColor: Theme.muted)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            footer
        }
        .background(Theme.panel)
    }

    // MARK: - Pieces

    private var brand: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            Text("MailBar").font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 34)   // 给左上角的红黄绿按钮让位
        .padding(.bottom, 8)
    }

    private func section<Content: View>(_ title: String, action: (icon: String, help: String, run: () -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(Theme.mono(10, .semibold)).tracking(1.6).foregroundStyle(Theme.faint)
                Spacer()
                if let action {
                    Button(action: action.run) { Image(systemName: action.icon).font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.faint)
                        .help(action.help)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
            content()
        }
    }

    /// 来源：回到收件箱并只看这个来源，数字是有未读的分组数。
    private func sourceRow(_ source: String, _ count: SourceCount) -> some View {
        let style = ReaderModel.style(forSource: source)
        let color = Theme.color(named: style.color)
        let selected = reader.mailbox == .label("INBOX") && reader.sourceFilter == source
        return Button { reader.selectSource(source) } label: {
            HStack(spacing: 8) {
                Image(systemName: style.icon).font(.system(size: 11.5)).foregroundStyle(selected ? Theme.accent : Theme.muted).frame(width: 16)
                Text(style.title == "文档" ? "Google 文档" : style.title)
                    .font(Theme.ui(12.5, selected ? .semibold : .regular)).foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.88)).lineLimit(1)
                Spacer(minLength: 4)
                if count.unreadGroups > 0 { CountBadge(count: count.unreadGroups, color: Theme.muted) }
                else { Text("\(count.groups)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.pad(4.5))
            .navSelected(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(icon: String, iconColor: Color, title: String, mailbox: Mailbox, badge: Int, badgeColor: Color) -> some View {
        let selected = reader.mailbox == mailbox && reader.sourceFilter == nil
        return Button { reader.select(mailbox) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(selected ? iconColor : iconColor.opacity(0.85)).frame(width: 16)
                Text(title).font(Theme.ui(12.5, selected ? .semibold : .regular)).foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.88)).lineLimit(1)
                Spacer(minLength: 4)
                CountBadge(count: badge, color: badgeColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.pad(4.5))
            .navSelected(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ruleRow(_ rule: Rule) -> some View {
        let mailbox = Mailbox.rule(rule.name)
        let selected = reader.mailbox == mailbox && reader.sourceFilter == nil
        let color = Theme.color(for: rule)
        return Button { reader.select(mailbox) } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7).frame(width: 16)
                Text(rule.name).font(Theme.ui(12.5, selected ? .semibold : .regular)).foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.88)).lineLimit(1)
                if rule.notify {
                    Image(systemName: rule.strong ? "exclamationmark.triangle.fill" : "bell.fill")
                        .font(.system(size: 8)).foregroundStyle(rule.strong ? Theme.red : Theme.faint)
                }
                Spacer(minLength: 4)
                CountBadge(count: ruleCount(rule.name), color: Theme.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.pad(4.5))
            .navSelected(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.border)
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if let account = service.accountEmail {
                        Text(account).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    if service.loginRequired {
                        Button("登录 Google…") { service.signIn() }.controlSize(.small)
                    }
                }
                Spacer()
                Button { service.manualSync() } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(service.syncing ? 360 : 0))
                        .animation(service.syncing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: service.syncing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(service.syncing ? Theme.accent : Theme.muted)
                .pointerStyle(.link)
                .help("立即收取邮件（⌘R）")
                Button { service.openSettings?("general") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("设置（⌘,）")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}
