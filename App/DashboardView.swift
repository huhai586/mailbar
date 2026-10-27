import MailCore
import SwiftUI

/// 没选邮件时的右侧：今日概览。比一片空白更有用 —— 直接列出最需要处理的未读重点邮件。
struct DashboardView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日概览").font(Theme.ui(22, .bold)).foregroundStyle(Theme.text)
                    Text(Date.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.wide)))
                        .font(Theme.mono(12)).foregroundStyle(Theme.faint)
                }

                HStack(spacing: 12) {
                    tile("待处理", reader.stats.attention, Theme.orange, icon: "exclamationmark.bubble.fill") { reader.select(.attention) }
                    tile("真人未读", reader.stats.humanUnread, Theme.accent, icon: "person.fill") { reader.select(.label("INBOX")) }
                    tile("例行机器人未读", reader.stats.routineUnread, Theme.muted, icon: "gearshape.2") { reader.cleanRoutine() }
                }
                if reader.stats.routineUnread > 0 {
                    Text("例行机器人邮件（质量门通过、包体积检查、测试汇总……）可以放心忽略，点上面最右边的卡片一键标为已读。")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.faint)
                }

                if reader.dashboard.isEmpty {
                    Label("没有待处理的邮件", systemImage: "checkmark.seal.fill")
                        .font(Theme.ui(13)).foregroundStyle(Theme.green)
                    if service.rules.filter(\.enabled).isEmpty { callout }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("待处理（出问题了，或和你相关的 PR 上有真人的新评论）").font(Theme.mono(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
                        VStack(spacing: 0) {
                            ForEach(reader.dashboard) { thread in
                                dashboardRow(thread)
                            }
                        }
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                shortcuts
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 56)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func tile(_ title: String, _ value: Int, _ color: Color, icon: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
                    Text(title).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                }
                Text("\(value)").font(Theme.mono(28, .bold)).foregroundStyle(value > 0 && color != Theme.muted ? color : Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(PlainPointerButtonStyle())
        .disabled(action == nil)
    }

    private func dashboardRow(_ thread: ThreadSummary) -> some View {
        let info = NotificationClassifier.classify(subject: thread.subject, from: thread.from, reason: thread.reason, body: thread.snippet)
        let rules = reader.rulesByName
        let top = thread.ruleNames.compactMap { rules[$0] }.max { Theme.priority(of: $0) < Theme.priority(of: $1) }
        return Button { reader.selectedThreadID = thread.id } label: {
            HStack(spacing: 10) {
                Circle().fill(top.map { Theme.color(for: $0) } ?? Theme.accent).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info?.title ?? thread.subject).font(Theme.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text([info?.context, info?.reference, MailAddress.parse(thread.from).displayName].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer()
                if let top { Chip(text: top.name, color: Theme.color(for: top), mono: false) }
                Text(DateText.list(thread.date)).font(Theme.mono(11)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPointerButtonStyle())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 0.5) }
    }

    private var callout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还没有启用任何规则", systemImage: "bolt.slash").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
            Text("规则会按关键词、发件人或 GitHub 通知原因给邮件打上彩色标签，重要的一眼就能看到。").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            HStack {
                Button("添加推荐规则（GitHub / Jira）") { service.addRecommendedRules() }
                Button("自己建规则…") { service.openSettings?("rules") }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷键").font(Theme.mono(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                KeyHint(keys: "j / k", label: "下一封 / 上一封")
                KeyHint(keys: "m", label: "标为已读 / 未读")
                KeyHint(keys: "u", label: "只看未读")
                KeyHint(keys: "/", label: "搜索")
                KeyHint(keys: "g", label: "在 GitHub 打开")
                KeyHint(keys: "o", label: "在 Gmail 打开")
                KeyHint(keys: "r", label: "立即同步")
                KeyHint(keys: "⌘K", label: "命令面板")
            }
        }
    }
}
