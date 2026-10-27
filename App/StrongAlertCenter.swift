import AppKit
import MailCore
import SwiftUI

/// 强提醒：始终置顶的提醒卡片 + 循环响铃 + Dock 图标跳动，直到用户点"查看"或"忽略"。
@MainActor
final class StrongAlertCenter: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let hit: RuleHit
    }

    @Published private(set) var items: [Item] = []
    /// 点"查看"时调用：打开对应会话
    var onOpen: ((RuleHit) -> Void)?
    /// 卡片出现 / 消失时调用，让 AppDelegate 更新 Dock 图标显示
    var onVisibilityChange: (() -> Void)?

    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt = Date()

    var isShowing: Bool { !items.isEmpty }

    func show(_ hits: [RuleHit]) {
        guard !hits.isEmpty else { return }
        let wasEmpty = items.isEmpty
        items += hits.map(Item.init)
        if wasEmpty { startedAt = Date() }
        presentPanel()
        ring()
        startRepeating()
        // 没有 Dock 图标的菜单栏应用不能让 Dock 跳动，所以先显示图标
        if Pref.strongBounce {
            NSApp.setActivationPolicy(.regular)
            NSApp.requestUserAttention(.criticalRequest)
        }
        onVisibilityChange?()
    }

    func open(_ item: Item) {
        remove(item.id)
        onOpen?(item.hit)
    }

    func dismiss(_ item: Item) { remove(item.id) }

    func dismissAll() {
        items.removeAll()
        finishIfEmpty()
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        finishIfEmpty()
        resizePanel()
    }

    private func finishIfEmpty() {
        guard items.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        onVisibilityChange?()
    }

    // MARK: - Sound

    private func ring() {
        var played = Set<String>()
        for item in items {
            let spec = item.hit.sound ?? Pref.strongSoundName
            if spec.lowercased() != "none", !spec.isEmpty, played.insert(spec).inserted { SoundLibrary.play(spec) }
        }
    }

    private func startRepeating() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Pref.strongRepeat, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isShowing else { return }
                let limit = Pref.strongMaxDuration
                if limit > 0, Date().timeIntervalSince(self.startedAt) > limit {
                    self.timer?.invalidate()   // 超过最长时长：不再响，卡片仍留着
                    return
                }
                self.ring()
                if Pref.strongBounce { NSApp.requestUserAttention(.criticalRequest) }
            }
        }
    }

    // MARK: - Panel

    private func presentPanel() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .screenSaver            // 盖在其他应用（包括全屏的）之上
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hasShadow = true
            panel.contentView = NSHostingView(rootView: StrongAlertView(center: self))
            self.panel = panel
        }
        resizePanel()
        panel?.orderFrontRegardless()
    }

    private func resizePanel() {
        guard let panel, let host = panel.contentView as? NSHostingView<StrongAlertView> else { return }
        let size = host.fittingSize
        panel.setContentSize(NSSize(width: 420, height: min(max(size.height, 120), 520)))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - panel.frame.height - 20))
        }
    }
}

struct StrongAlertView: View {
    @ObservedObject var center: StrongAlertCenter

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("强提醒").font(.headline)
                Text("\(center.items.count) 封").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if center.items.count > 1 {
                    Button("全部忽略") { center.dismissAll() }.controlSize(.small)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(center.items) { item in card(item) }
                }
            }
            .frame(maxHeight: 380)
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.7), lineWidth: 2))
    }

    private func card(_ item: StrongAlertCenter.Item) -> some View {
        let hit = item.hit
        return VStack(alignment: .leading, spacing: 4) {
            Text("规则：\(hit.ruleName)")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.2), in: Capsule())
            Text(MailAddress.parse(hit.from).displayName).fontWeight(.semibold)
            Text(hit.subject.isEmpty ? "（无主题）" : hit.subject).lineLimit(2)
            if !hit.snippet.isEmpty {
                Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Spacer()
                Button("忽略") { center.dismiss(item) }
                Button("查看") { center.open(item) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}
