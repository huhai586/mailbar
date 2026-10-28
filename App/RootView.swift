import AppKit
import MailCore
import SwiftUI

/// 系统「增强对比度」的开关状态。Theme 的颜色在绘制时读它；它变了要让整个界面重新取一遍颜色（见 RootView 的 .id）。
@MainActor
final class DisplayOptions: ObservableObject {
    @Published private(set) var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
        }
    }

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}

struct RootView: View {
    @ObservedObject var service: MailService
    @StateObject private var reader: ReaderModel
    @StateObject private var calendarModel: CalendarModel
    @StateObject private var display = DisplayOptions()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Pref.appearance) private var appearance = "dark"
    @AppStorage(Pref.fontOffset) private var fontOffset = 0.0
    @AppStorage(Pref.uiDensity) private var uiDensity = "standard"
    @AppStorage(Pref.fontSet) private var fontSet = "jetbrains"
    @AppStorage(Pref.sidebarVisible) private var sidebarVisible = true
    @Environment(\.undoManager) private var undoManager

    init(service: MailService) {
        self.service = service
        _reader = StateObject(wrappedValue: ReaderModel(service: service))
        _calendarModel = StateObject(wrappedValue: CalendarModel(service: service))
    }

    /// 菜单栏命令：这里持有列表和详情的状态，由它来执行。
    private func performCommand(_ command: AppCommand) {
        switch command {
        case .toggleRead: if let id = reader.selectedThreadID { reader.toggleRead(threadId: id) }
        case .previousThread: reader.moveSelection(by: -1)
        case .nextThread: reader.moveSelection(by: 1)
        case .focusSearch: service.module = .mail; reader.focusSearchTick += 1
        case .toggleUnreadOnly: reader.unreadOnly.toggle()
        case .openInService: if let link = reader.serviceLink() { NSWorkspace.shared.open(link.url) }
        case .openInGmail:
            NSWorkspace.shared.open(gmailURL(threadId: reader.selectedThread?.latestThreadId ?? reader.selectedThreadID, account: service.accountEmail))
        case .commandPalette: service.module = .mail; reader.showPalette.toggle()
        }
    }

    private func updateMenuState() {
        let state = MenuState(hasSelection: reader.selectedThreadID != nil, hasUnread: reader.selectedThreadHasUnread,
                              hasServiceLink: reader.selectedThreadID != nil && reader.serviceLink() != nil,
                              mailVisible: service.module == .mail)
        if state != service.menuState { service.menuState = state }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !service.hasAccounts {
                WelcomeView(service: service)
            } else {
                // 侧栏始终在；选了「日历」时中间和右边两栏换成日历（日程列表 + 日 / 周 / 月视图）
                HSplitView {
                    if sidebarVisible {
                        SidebarView(reader: reader, service: service)
                            .frame(minWidth: 190, idealWidth: 218, maxWidth: 300, maxHeight: .infinity)
                    }
                    if service.module == .calendar {
                        CalendarAgenda(model: calendarModel, service: service)
                            .frame(minWidth: 300, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)
                        CalendarMain(model: calendarModel, service: service)
                            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ThreadListView(reader: reader, service: service)
                            .frame(minWidth: 340, idealWidth: 450, maxWidth: 720, maxHeight: .infinity)
                        ThreadDetailView(reader: reader, service: service)
                            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            StatusBar(service: service, reader: reader)
        }
        .id("\(fontOffset)|\(uiDensity)|\(fontSet)|\(appearance)|\(display.increaseContrast)")   // 字号 / 密度一变就整体重建，所有 Theme.ui / pad 重新取值
        .background(Theme.bg)
        .overlay {
            if reader.showPalette {
                CommandPalette(commands: reader.paletteCommands()) { reader.showPalette = false }
            }
        }
        .background(WindowConfigurator())
        .applyAppearance(appearance)
        .frame(minWidth: 1020, minHeight: 600)
        .onChange(of: undoManager) { service.undoManager = undoManager }
        .onChange(of: reader.selectedThreadID) { updateMenuState() }
        .onChange(of: reader.messages) { updateMenuState() }
        .onAppear {
            // 菜单栏的"打开邮件窗口"靠它在窗口被关闭后重新打开
            service.openMainWindow = { openWindow(id: "main") }
            service.openSettingsWindow = { openSettings() }
            service.undoManager = undoManager
            service.perform = { command in performCommand(command) }
            updateMenuState()
            #if DEBUG
            // 调试用：`--args -openPalette YES` 启动后直接展开命令面板，方便截图检查
            if UserDefaults.standard.bool(forKey: "openPalette") { reader.showPalette = true }
            #endif
        }
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
            Circle().fill(dotColor).frame(width: 7, height: 7).accessibilityHidden(true)   // 状态已经写在旁边的文字里
            Text(service.statusLine).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            Text("未读 \(reader.stats.inboxUnread)").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
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
        installZoomOnDoubleClick(for: window)
        redirectCloseToMinimize(window)
    }

    /// 红色关闭按钮和 ⌘W 都改成最小化到 Dock，而不是关掉窗口：窗口留在 Dock 里，点一下就回来，应用也始终在运行。
    /// 退出请用菜单栏图标里的「退出」或 ⌘Q。
    private static func redirectCloseToMinimize(_ window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton), !(button.target is CloseToMinimize) else { return }
        let handler = CloseToMinimize(window)
        objc_setAssociatedObject(button, &CloseToMinimize.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        button.target = handler
        button.action = #selector(CloseToMinimize.minimize)
        if closeKeyMonitor == nil {
            closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
                guard let window, event.window === window, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "w" else { return event }
                window.miniaturize(nil)
                return nil
            }
        }
    }

    private static var closeKeyMonitor: Any?

    private static var zoomMonitor: Any?

    /// 标题被隐藏后系统不再处理标题栏双击；这里补上：双击窗口顶部 = 放大到屏幕可用区域（再双击还原），不进入全屏。
    private static func installZoomOnDoubleClick(for window: NSWindow) {
        guard zoomMonitor == nil else { return }
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, event.window === window, !window.styleMask.contains(.fullScreen) else { return event }
            guard event.locationInWindow.y >= window.frame.height - 28 else { return event }
            if let hit = window.contentView?.hitTest(event.locationInWindow), hit is NSControl || hit is NSText { return event }
            window.zoom(nil)
            return nil
        }
    }
}

/// 红色关闭按钮的新动作：最小化。
final class CloseToMinimize: NSObject {
    static var key = 0
    private weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
    @objc func minimize() {
        window?.miniaturize(nil)
    }
}
