import AppKit
import MailCore
import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let hint: String
    let icon: String
    let run: () -> Void
}

/// ⌘K 命令面板：输入几个字就能跳到任意邮箱、规则，或执行同步、标记已读等操作。
struct CommandPalette: View {
    let commands: [PaletteCommand]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var filtered: [PaletteCommand] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return commands }
        return commands.filter { command in
            let haystack = (command.title + " " + command.hint).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.green)
                    TextField("输入命令或要跳转的邮箱 / 规则…", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(14))
                        .focused($focused)
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { dismiss(); return .handled }
                        .onSubmit(runSelected)
                }
                .padding(12)
                Rectangle().fill(Theme.border).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                                row(command, active: index == selected)
                                    .id(command.id)
                                    .onTapGesture { run(command) }
                            }
                            if filtered.isEmpty {
                                Text("没有匹配的命令").font(Theme.mono(12)).foregroundStyle(Theme.faint).padding(20)
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selected) { _, index in
                        if filtered.indices.contains(index) { proxy.scrollTo(filtered[index].id) }
                    }
                }
            }
            .frame(width: 560)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func row(_ command: PaletteCommand, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 18)
            Text(command.title).font(Theme.ui(13)).foregroundStyle(Theme.text)
            Spacer()
            Text(command.hint).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(active ? Theme.selection : .clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = min(max(selected + delta, 0), filtered.count - 1)
    }

    private func runSelected() {
        if filtered.indices.contains(selected) { run(filtered[selected]) }
    }

    private func run(_ command: PaletteCommand) {
        dismiss()
        DispatchQueue.main.async { command.run() }
    }
}

extension ReaderModel {
    /// 命令面板里的全部命令：跳转 + 操作。
    func paletteCommands() -> [PaletteCommand] {
        var list: [PaletteCommand] = []
        let service = self.service

        // 操作
        list.append(PaletteCommand(title: "立即同步", hint: "r", icon: "arrow.clockwise") { service.manualSync() })
        list.append(PaletteCommand(title: unreadOnly ? "显示全部邮件" : "只看未读", hint: "u", icon: "envelope.badge") { [self] in unreadOnly.toggle() })
        if let id = selectedThreadID {
            list.append(PaletteCommand(title: selectedThreadHasUnread ? "把当前会话标为已读" : "把当前会话标为未读", hint: "m", icon: "envelope.open") { [self] in
                toggleRead(threadId: id)
            })
            let gmailThread = selectedThread?.latestThreadId ?? id
            list.append(PaletteCommand(title: "在 Gmail 中打开当前会话", hint: "o", icon: "arrow.up.right.square") {
                NSWorkspace.shared.open(gmailURL(threadId: gmailThread, account: service.accountEmail))
            })
            if let link = serviceLink() {
                list.append(PaletteCommand(title: "在 \(link.name) 中打开", hint: "g", icon: link.icon) { NSWorkspace.shared.open(link.url) })
            }
            list.append(PaletteCommand(title: groupByPR ? "按会话列出（取消 PR 聚合）" : "按 PR 聚合", hint: "p", icon: "square.stack.3d.up") { [self] in groupByPR.toggle() })
        }
        list.append(PaletteCommand(title: service.paused ? "恢复同步与提醒" : "暂停同步与提醒", hint: "同步", icon: service.paused ? "play.circle" : "pause.circle") {
            service.togglePause()
        })
        list.append(PaletteCommand(title: "加载更早的邮件", hint: "同步", icon: "clock.arrow.circlepath") {
            Task { await service.loadOlder(count: Pref.olderBatch) }
        })
        list.append(PaletteCommand(title: "管理规则", hint: "设置", icon: "slider.horizontal.3") { service.openSettings?("rules") })
        list.append(PaletteCommand(title: "打开设置", hint: "⌘,", icon: "gearshape") { service.openSettings?("general") })
        if service.rules.isEmpty || !service.rules.contains(where: \.enabled) {
            list.append(PaletteCommand(title: "添加推荐规则（GitHub / Jira）", hint: "规则", icon: "wand.and.stars") { service.addRecommendedRules() })
        }

        if stats.routineUnread > 0 {
            list.append(PaletteCommand(title: "清理 \(stats.routineUnread) 条例行机器人未读", hint: "已读", icon: "gearshape.2") { [self] in cleanRoutine() })
        }

        // 跳转
        list.append(PaletteCommand(title: "转到 待处理", hint: "分诊", icon: "exclamationmark.bubble.fill") { [self] in select(.attention) })
        for source in Self.sourceOrder {
            let style = Self.style(forSource: source)
            list.append(PaletteCommand(title: "只看 \(style.title == "文档" ? "Google 文档" : style.title)", hint: "来源", icon: style.icon) { [self] in selectSource(source) })
        }
        list.append(PaletteCommand(title: "转到 重点", hint: "邮箱", icon: "bolt.fill") { [self] in select(.important) })
        for item in SystemMailbox.all {
            list.append(PaletteCommand(title: "转到 \(item.title)", hint: "邮箱", icon: item.icon) { [self] in select(item.mailbox) })
        }
        for rule in service.rules.filter(\.enabled) {
            list.append(PaletteCommand(title: "筛选 规则：\(rule.name)", hint: "规则", icon: "line.3.horizontal.decrease") { [self] in select(.rule(rule.name)) })
        }
        for label in labels where label.type == "user" {
            list.append(PaletteCommand(title: "转到 标签：\(label.name)", hint: "标签", icon: "tag") { [self] in select(.label(label.id)) })
        }
        return list
    }
}
