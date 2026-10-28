import AppKit
import MailCore
import SwiftUI

/// 应用自己的通知卡片：像系统通知横幅一样出现在屏幕右上角，但显示多久由设置决定（系统通知的时长由 macOS 控制，应用改不了）。
struct ToastItem: Identifiable, Equatable {
    enum Kind { case mail, calendar }
    let id = UUID()
    var kind: Kind = .mail
    var title: String
    var body: String
    var accountID: String?
    var threadId: String?
    /// 日程提醒上的「加入会议」
    var joinURL: URL?
    /// AI 判断过的邮件才有 👍 / 👎
    var judgedMessageId: String?
}

@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var items: [ToastItem] = []
    /// 点卡片：打开对应的邮件 / 日历
    var onOpen: ((ToastItem) -> Void)?
    var onFeedback: ((ToastItem, Int) -> Void)?

    private var panel: NSPanel?
    private var timers: [UUID: Task<Void, Never>] = [:]
    private static let maxVisible = 4

    func show(_ item: ToastItem) {
        items.append(item)
        while items.count > Self.maxVisible { remove(items[0].id) }
        startTimer(item.id)
        present()
    }

    func dismiss(_ id: UUID) { remove(id) }

    func open(_ item: ToastItem) {
        remove(item.id)
        onOpen?(item)
    }

    func feedback(_ item: ToastItem, _ value: Int) {
        onFeedback?(item, value)
        remove(item.id)
    }

    /// 鼠标放在卡片上时暂停倒计时，移开后重新计时。
    func hover(_ id: UUID, _ inside: Bool) {
        if inside { timers[id]?.cancel(); timers[id] = nil } else if items.contains(where: { $0.id == id }) { startTimer(id) }
    }

    private func startTimer(_ id: UUID) {
        timers[id]?.cancel()
        let seconds = Pref.toastDuration
        guard seconds > 0 else { timers[id] = nil; return }   // 0 = 一直显示到点击
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.remove(id)
        }
    }

    private func remove(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        items.removeAll { $0.id == id }
        if items.isEmpty { panel?.orderOut(nil) } else { resize() }
    }

    private func present() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: ToastStack(center: self))
            self.panel = panel
        }
        resize()
        panel?.orderFrontRegardless()
    }

    private func resize() {
        guard let panel, let host = panel.contentView as? NSHostingView<ToastStack> else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(NSSize(width: 380, height: max(size.height, 1)))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 12, y: frame.maxY - panel.frame.height - 8))
        }
    }
}

private struct ToastStack: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.items) { item in ToastCard(center: center, item: item) }
        }
        .padding(8)
        .frame(width: 380)
    }
}

private struct ToastCard: View {
    @ObservedObject var center: ToastCenter
    let item: ToastItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind == .calendar ? "calendar" : "envelope.fill")
                .font(.system(size: 18)).foregroundStyle(item.kind == .calendar ? Color.red : Color.accentColor)
                .frame(width: 24).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !item.body.isEmpty { Text(item.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
                HStack(spacing: 8) {
                    if let url = item.joinURL {
                        Button("加入会议") { NSWorkspace.shared.open(url); center.dismiss(item.id) }.controlSize(.small)
                    }
                    if item.judgedMessageId != nil {
                        Button("👍 有用") { center.feedback(item, 1) }.controlSize(.small)
                        Button("👎 没用") { center.feedback(item, -1) }.controlSize(.small)
                    }
                }
                .padding(.top, item.joinURL != nil || item.judgedMessageId != nil ? 3 : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { center.dismiss(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).padding(6)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { center.open(item) }
        .onHover { inside in hovering = inside; center.hover(item.id, inside) }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
