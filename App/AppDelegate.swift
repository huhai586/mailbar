import AppKit
import Combine
import MailCore
import os

private let log = Logger(subsystem: "com.huhai.mailbar", category: "app")

/// 菜单栏图标 + 应用生命周期。同步和状态都在 MailService 里，这里只负责呈现和转发操作。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let service = MailService()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables = Set<AnyCancellable>()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 菜单里"规则命中"子菜单项携带的跳转目标
    private final class Destination: NSObject {
        let mailbox: Mailbox?
        let threadId: String?
        init(mailbox: Mailbox?, threadId: String?) {
            self.mailbox = mailbox
            self.threadId = threadId
        }
    }

    // MARK: - Lifecycle

    override init() {
        Pref.register()   // 先登记默认值，之后所有地方读到的设置都一致
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.notifier.onOpenThread = { [weak self] threadId in
            self?.showMainWindow(mailbox: nil, threadId: threadId)
        }
        service.strongAlerts.onOpen = { [weak self] hit in
            self?.showMainWindow(mailbox: nil, threadId: hit.threadId)
        }
        service.strongAlerts.onVisibilityChange = { [weak self] in self?.updateActivationPolicy() }
        service.openSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        service.start()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        service.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.updateIcon() }.store(in: &cancellables)

        if !Pref.openWindowOnLaunch {
            // 设置里关了"启动时打开主窗口"：等 SwiftUI 把窗口建出来再关掉，只留菜单栏图标
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
                self?.updateActivationPolicy()
            }
        }
        #if DEBUG
        // 调试用：`--args -openSettings YES -settingsTab rules` 启动后直接打开设置窗口，方便截图检查
        if UserDefaults.standard.bool(forKey: "openSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showSettings(tab: UserDefaults.standard.string(forKey: Pref.settingsTab) ?? "general")
            }
        }
        #endif

        // 有窗口时显示 Dock 图标（可 ⌘Tab 切换），窗口都关了就只留菜单栏
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.updateActivationPolicy() }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        service.syncIfStale()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(mailbox: nil, threadId: nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && ($0.canBecomeMain || $0.title.contains("设置") || $0.title.lowercased().contains("settings")) }
        // 强提醒要让 Dock 图标跳动，显示期间也需要 Dock 图标
        let bounce = service.strongAlerts.isShowing && Pref.strongBounce
        NSApp.setActivationPolicy(hasWindow || bounce ? .regular : .accessory)
    }

    private func showSettings(tab: String) {
        UserDefaults.standard.set(tab, forKey: Pref.settingsTab)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let open = service.openSettingsWindow {
            open()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private func showMainWindow(mailbox: Mailbox?, threadId: String?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let open = service.openMainWindow {
            open()
        } else {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        if mailbox != nil || threadId != nil { service.requestNavigation(mailbox: mailbox, threadId: threadId) }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        service.markHitsSeen()

        menu.addItem(disabledItem(service.statusLine))
        if let warning = service.ruleWarning {
            menu.addItem(disabledItem("⚠️ 规则: " + (warning.split(separator: "\n").first.map(String.init) ?? warning)))
        }
        menu.addItem(actionItem("打开邮件窗口", #selector(openWindow), key: "o"))
        menu.addItem(actionItem("立即同步", #selector(syncNow), key: "r"))
        menu.addItem(actionItem(service.paused ? "恢复同步与提醒" : "暂停同步与提醒", #selector(togglePause)))
        if service.loginRequired { menu.addItem(actionItem("登录 Google…", #selector(signIn))) }
        menu.addItem(.separator())

        let rulesItem = NSMenuItem(title: "规则命中", action: nil, keyEquivalent: "")
        rulesItem.submenu = rulesSubmenu()
        menu.addItem(rulesItem)
        menu.addItem(actionItem("管理规则…", #selector(manageRules)))
        menu.addItem(actionItem("设置…", #selector(openSettingsWindow), key: ","))
        menu.addItem(.separator())

        menu.addItem(actionItem("退出", #selector(quit), key: "q"))
    }

    private func rulesSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let store = service.store
        let counts = (try? store?.matchCounts()) ?? []
        if counts.isEmpty {
            submenu.addItem(disabledItem("（还没有命中，或还没启用规则）"))
            return submenu
        }
        for entry in counts {
            let all = actionItem("\(entry.name)（\(entry.count)）", #selector(openDestination(_:)))
            all.representedObject = Destination(mailbox: .rule(entry.name), threadId: nil)
            let messages = NSMenu()
            for m in (try? store?.matches(rule: entry.name, limit: 10)) ?? [] {
                let title = "\(timeFormatter.string(from: m.date))  \(String(m.subject.prefix(60)))"
                let item = actionItem(title, #selector(openDestination(_:)))
                item.representedObject = Destination(mailbox: .rule(entry.name), threadId: m.threadId)
                messages.addItem(item)
            }
            all.submenu = messages
            submenu.addItem(all)
        }
        return submenu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateIcon() {
        // 自绘的模板图标（见 tools/make-icon.swift）：信封 + >_；有未看的命中时带一个提醒点
        let image = NSImage(named: service.hasUnseenHits ? "MenuBarIconBadge" : "MenuBarIcon")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = service.paused
        // 图标旁边显示未读重点邮件数
        let important = (try? service.store?.unreadThreadCount(in: .important)) ?? 0
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = important > 0 ? " \(important)" : ""
    }

    // MARK: - Actions

    @objc private func openWindow() { showMainWindow(mailbox: nil, threadId: nil) }
    @objc private func syncNow() { service.manualSync() }
    @objc private func togglePause() { service.togglePause() }
    @objc private func signIn() { service.signIn() }

    @objc private func openDestination(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? Destination else { return }
        showMainWindow(mailbox: destination.mailbox, threadId: destination.threadId)
    }

    @objc private func manageRules() { showSettings(tab: "rules") }
    @objc private func openSettingsWindow() { showSettings(tab: UserDefaults.standard.string(forKey: Pref.settingsTab) ?? "general") }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
