import AppKit
import SwiftUI

/// 菜单栏里的应用命令。快捷键只用带修饰键的（⌘R、⌘K、⌘F……）：m / j / k 这类单键由列表自己处理，
/// 放进菜单会在输入框里打字时被菜单抢走。菜单项的启用状态来自 service.menuState（由 RootView 随选中项更新）。
enum AppCommand {
    case toggleRead, previousThread, nextThread, focusSearch, toggleUnreadOnly
    case openInService, openInGmail, commandPalette
}

struct MenuState: Equatable {
    var hasSelection = false
    var hasUnread = false
    var hasServiceLink = false
    var mailVisible = true
}

struct AppCommands: Commands {
    @ObservedObject var service: MailService
    @AppStorage(Pref.sidebarVisible) private var sidebarVisible = true

    var body: some Commands {
        // 编辑 > 查找：搜索邮件
        CommandGroup(after: .textEditing) {
            Button("搜索邮件") { service.perform?(.focusSearch) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!service.menuState.mailVisible)
        }

        // 视图：侧栏、模块切换
        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisible ? "隐藏侧栏" : "显示侧栏") { sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button("邮件") { service.module = .mail }
                .keyboardShortcut("1", modifiers: .command)
            Button("日历") { service.module = .calendar }
                .keyboardShortcut("2", modifiers: .command)
        }

        CommandMenu("邮件") {
            Button("立即同步") { service.manualSync() }
                .keyboardShortcut("r", modifiers: .command)
            Button(service.paused ? "恢复同步与提醒" : "暂停同步与提醒") { service.togglePause() }
            Divider()
            Button(service.menuState.hasUnread ? "标为已读" : "标为未读") { service.perform?(.toggleRead) }
                .disabled(!service.menuState.hasSelection)
            Button("上一封") { service.perform?(.previousThread) }
                .disabled(!service.menuState.mailVisible)
            Button("下一封") { service.perform?(.nextThread) }
                .disabled(!service.menuState.mailVisible)
            Button("只看未读") { service.perform?(.toggleUnreadOnly) }
                .disabled(!service.menuState.mailVisible)
            Divider()
            Button("在 GitHub / Jira 中打开") { service.perform?(.openInService) }
                .disabled(!service.menuState.hasServiceLink)
            Button("在 Gmail 中打开") { service.perform?(.openInGmail) }
                .disabled(!service.menuState.hasSelection)
            Divider()
            Button("命令面板") { service.perform?(.commandPalette) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!service.menuState.mailVisible)
        }
    }
}
