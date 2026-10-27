import AppKit
import MailCore
import SwiftUI

struct RootView: View {
    @ObservedObject var service: MailService
    @StateObject private var reader: ReaderModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Pref.appearance) private var appearance = "dark"
    @AppStorage(Pref.fontOffset) private var fontOffset = 0.0
    @AppStorage(Pref.uiDensity) private var uiDensity = "standard"

    init(service: MailService) {
        self.service = service
        _reader = StateObject(wrappedValue: ReaderModel(service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SidebarView(reader: reader, service: service)
                    .frame(minWidth: 190, idealWidth: 218, maxWidth: 300, maxHeight: .infinity)
                ThreadListView(reader: reader, service: service)
                    .frame(minWidth: 340, idealWidth: 450, maxWidth: 720, maxHeight: .infinity)
                ThreadDetailView(reader: reader, service: service)
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            StatusBar(service: service, reader: reader)
        }
        .id("\(fontOffset)|\(uiDensity)")   // 字号 / 密度一变就整体重建，所有 Theme.ui / pad 重新取值
        .background(Theme.bg)
        .overlay {
            if reader.showPalette {
                CommandPalette(commands: reader.paletteCommands()) { reader.showPalette = false }
            }
        }
        .background(WindowConfigurator())
        .background(shortcutButtons)
        .applyAppearance(appearance)
        .frame(minWidth: 1020, minHeight: 600)
        .onAppear {
            // 菜单栏的"打开邮件窗口"靠它在窗口被关闭后重新打开
            service.openMainWindow = { openWindow(id: "main") }
            service.openSettingsWindow = { openSettings() }
            #if DEBUG
            // 调试用：`--args -openPalette YES` 启动后直接展开命令面板，方便截图检查
            if UserDefaults.standard.bool(forKey: "openPalette") { reader.showPalette = true }
            #endif
        }
    }

    /// 不可见的按钮，只为了挂全局快捷键。
    private var shortcutButtons: some View {
        ZStack {
            Button("") { reader.showPalette.toggle() }.keyboardShortcut("k", modifiers: .command)
            Button("") { reader.focusSearchTick += 1 }.keyboardShortcut("f", modifiers: .command)
            Button("") { service.manualSync() }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

/// 底部状态栏：同步状态、计数、快捷键提示。
private struct StatusBar: View {
    @ObservedObject var service: MailService
    @ObservedObject var reader: ReaderModel

    private var dotColor: Color {
        if service.setupError != nil || service.loginRequired || service.lastError != nil { return Theme.red }
        if service.paused { return Theme.faint }
        return service.syncing || service.loadingOlder ? Theme.orange : Theme.green
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(service.statusLine).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            Text("未读 \(reader.stats.inboxUnread)").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
            Text("重点 \(reader.stats.importantUnread)").font(Theme.mono(10.5))
                .foregroundStyle(reader.stats.importantUnread > 0 ? Theme.orange : Theme.muted)
            Rectangle().fill(Theme.border).frame(width: 1, height: 12)
            KeyHint(keys: "j/k", label: "移动")
            KeyHint(keys: "m", label: "已读")
            KeyHint(keys: "/", label: "搜索")
            KeyHint(keys: "⌘K", label: "命令")
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 让窗口内容延伸到标题栏下面：隐藏标题、标题栏透明、可以拖背景移动窗口。
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(view.window) }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
    }
}
